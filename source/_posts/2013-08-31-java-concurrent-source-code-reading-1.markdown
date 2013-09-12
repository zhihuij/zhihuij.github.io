---
layout: post
title: "Java并发源码分析 - 锁"
date: 2013-08-31 16:07
comments: true
categories: java concurrent lock
---
（注：文章里涉及到的代码分析，基于jdk1.7.0_10 Hotspot 64-Bit）

##基本概念

Java同步机制除了内置的synchronized（包含Object.wait/notify）以外，还通过concurrent包提供了多种锁，包含ReentrantLock、Semaphore、ReentrantReadWriteLock等，以及跟Object.wait/notify类似语义的Condition接口。

#### 接口定义

具体的接口（Lock，Condition）就不在这里赘述，只做个简单总结：

> 1. Lock接口提供三种不同类型的获取锁接口：不响应中断（interrupt）、响应中断、可以设置超时；
> 2. Condition接口提供类似Object.wait语义的四种await接口：不响应中断（interrupt）、响应中断、可以设置超时、可以设置deadline；不管哪一种await，都必须在调用前持有跟该Condition对象关联的锁，Condition的实现会保证await调用在进入阻塞状态前释放锁，并且在await调用返回时，重新持有锁。

#### 锁类型

> 1. 同synchronized一样，concurrent包里提供的锁都是可重入的（reentrant）：一个线程在持有一个锁时，在不释放该锁的前提下，可多次重新持有该锁；
> 2. 互斥锁和共享锁：在一个线程持有锁的时候，如果其它线程不能再持有该锁，则为互斥锁，否则为共享锁；concurrent包里的ReentrantLock为互斥锁，Semaphore为共享锁，ReentrantReadWriteLock是共享锁及互斥锁的结合；
> 3. 公平锁和非公平锁：公平锁保证线程以FIFO的顺序持有锁（不包含tryLock接口），但非公平锁不保证这点：在有线程在排队等待获取当前锁的时候，新的线程可以直接竞争成功并持有锁；

##基本框架

简单查看一下ReetrantLock、Semaphore等类的实现，会发现都依赖于AbstractQueuedSynchronizer（AQS）这个类，这个其实是concurrent包里实现同步机制的一个核心框架，可以通过这篇[论文][aqs]来了解这个框架。该框架的核心实现要素包含以下三点：

> 1. 同步状态的原子性管理
> 2. 等待队列的管理
> 3. 线程的阻塞和唤醒

####同步状态的原子性管理

AQS将状态定义为一个整型变量（volatile int state），对它的修改AQS提供了两个接口，一个是基于volatile语义：

<pre class="prettyprint linenums:549 lang-java">
    protected final void setState(int newState) {
        state = newState;
    }
</pre>

另外一个依赖于Unsafe.compareAndSwapInt：

<pre class="prettyprint linenums:564 lang-java">
    protected final boolean compareAndSetState(int expect, int update) {
        // See below for intrinsics setup to support this
        return unsafe.compareAndSwapInt(this, stateOffset, expect, update);
    }
</pre>

那什么时候用setState，什么时候用compareAndSetState呢？简单看了下调用关系，有如下特征：

> * 初始化state时一般用setState，比如：Semaphore、CountDownLatch、ReentrantReadWriteLock等的AQS子类初始化；
> * 互斥锁的可重入处理逻辑中一般调用setState，比如：ReentrantLock的tryAcquire，ReentrantReadWriteLock的tryAcquire；
> * 互斥锁的释放锁操作一般调用setState，比如：ReentrantLock的tryRelease，ReentrantReadWriteLock的tryRelease；
> * 其它情况下都调用compareAndSetState。

从以上的情况来看，应该是在基本无竞争（初始化，重入处理、互斥锁的释放）的情况下调用setState；竞争比较激烈的情况下调用compareAndSetState。

####等待队列的管理

AQS使用CLH队列的变种来管理等待线程：每个等待线程为一个结点（AbstractQueuedSynchronizer.Node）。后文会混用结点和线程。

####线程的阻塞和唤醒
依赖于LockSupport.park（阻塞当前线程，实际调用Unsafe.park）及LockSupport.unpark（唤醒指定线程，实际调用Unsafe.unpark）；根据LockSupport的Java doc可以了解到以下内容：
> * park与unpark使用类似Semaphore的许可机制，如果当前线程拥有许可，那个park会消费掉该许可，并立即返回；如果当前线程没有许可，则当前线程会阻塞；unpark会导致指定线程的许可可用；
> * 许可不会累加，最多只有一个，也就是说连续多次的unpark并不会导致许可变多，也就是说如下[代码][locksuport]还是会导致当前线程阻塞：

<pre class="prettyprint linenums lang-java">
LockSupport.unpark(Thread.currentThread());  
LockSupport.unpark(Thread.currentThread());  
LockSupport.park();  
LockSupport.park();  
</pre>

> * 关于park()和park(Object blocker)的区别，Object blocker参数的作用在于允许记录当前线程被阻塞的原因，以便监控分析工具进行分析。官方的文档中也更建议使用park(Object blocker)。

###AQS实现

分析AQS之前先了解下concurrent包里的类是如何使用AQS的。AQS是抽象类，ReentrantLock、Semaphore等类会在使用时定义一个子类（Sync，一般还会根据是否是公平锁定义FireSync、NonfairSync），根据具体的需要重写AQS定义的四个protected接口：

<pre class="prettyprint linenums lang-java">
/**
 * 用于互斥锁。
 */
protected boolean tryAcquire(int arg);
protected boolean tryRelease(int arg);

/**
 * 用于共享锁。
 */
protected int tryAcquireShared(int arg);
protected boolean tryReleaseShared(int arg);
</pre>

注意返回值上，只有tryAcquireShared的返回值为int：大于0时，代表当前获取锁成功，后续的获取锁请求也可能会成功；等于0时，代表当前获取锁成功，后续获取锁请求必须等待；小于0时，代表当前获取锁失败，必须等待；其它返回值都为boolean，true则成功，false失败。

上述这几个接口的主要作用是什么呢？将管理锁（或者其它实现）的状态的任务交给具体实现类，这样AQS就不需要知道各个不同锁机制的状态之间的差别，从而简化AQS的实现。

然后具体的锁实现会调用AQS定义的几个公有方法来获取或者释放锁：
<pre class="prettyprint linenums lang-java">
/**
 * 用于互斥锁：分别对应不响应中断、响应中断、可设置超时的获取锁接口.
 */
public final void acquire(int arg);
public final void acquireInterruptibly(int arg) throws InterruptedException;
public final boolean tryAcquireNanos(int arg, long nanosTimeout) throws InterruptedException;
public final boolean release(int arg);

/**
 * 用于共享锁：分别对应不响应中断、响应中断、可设置超时的获取锁接口.
 */
public final void acquireShared(int arg);
public final void acquireSharedInterruptibly(int arg) throws InterruptedException;
public final boolean tryAcquireSharedNanos(int arg, long nanosTimeout) throws InterruptedException;
public final boolean releaseShared(int arg);
</pre>

####addWaiter：等待队列的加入

<pre class="prettyprint linenums:605 lang-java">
    private Node addWaiter(Node mode) {
        Node node = new Node(Thread.currentThread(), mode);
        // Try the fast path of enq; backup to full enq on failure
        Node pred = tail;
        if (pred != null) {
        	/**
        	 * 通过CAS来更改队列tail结点。        	 
        	 * 注意：在并发访问时，这里的CAS成功，可以保证prev结点非null，但next结点有可能为null。
        	 */
            node.prev = pred;
            if (compareAndSetTail(pred, node)) {
                pred.next = node;
                return node;
            }
        }
        enq(node);
        return node;
    }
</pre>

<pre class="prettyprint linenums:605 lang-java">
    private Node enq(final Node node) {
        for (;;) {
            Node t = tail;
            if (t == null) { // Must initialize
            	 /**
            	  * 这里多了个初始化：也就是有需要时才初始化head结点。
            	  */
                if (compareAndSetHead(new Node()))
                    tail = head;
            } else {
            	/**
        	 	 * 通过CAS来更改队列tail结点。
        	     * 注意：在并发访问时，这里的CAS成功，可以保证prev结点非null，但next结点有可能为null。
        	     */
                node.prev = t;
                if (compareAndSetTail(t, node)) {
                    t.next = node;
                    return t;
                }
            }
        }
    }
</pre>

从上面的代码可以知道，结点的加入只是简单的通过CAS更新队列的tail字段：保证prev跟tail的原子更新，但不保证tail与next的原子更新。

####acquire：互斥锁获取

<pre class="prettyprint linenums:1196 lang-java">
    public final void acquire(int arg) {
    	/*
    	 * 调用具体实现类的tryAcquire，如果返回true，则认为获取锁成功，当前函数返回；
    	 * 如果返回false，则将当前线程加入锁的等待队列（addWaiter，并且注意这里的加的
    	 * 等待结点类型为Node.EXCLUSIVE，也就是互斥锁），当前线程会进入休眠（dormant）
    	 * 状态，并等待前继结点唤醒，然后重新竞争锁，直到获取锁后返回。
    	 *
    	 * acquireQueued返回true说明线程在等待过程中被中断过（interrupted），则通过
    	 * selfInterrupt（实际调用Thread.currentThread().interrupt()）重新
    	 * interrupte当前线程以向调用者传递中断信号。
    	 */
        if (!tryAcquire(arg) &&
            acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
            selfInterrupt();
    }
</pre>

<pre class="prettyprint linenums:855 lang-java">
    final boolean acquireQueued(final Node node, int arg) {
        boolean failed = true;
        try {
            boolean interrupted = false;
            for (;;) {
                final Node p = node.predecessor();
                if (p == head && tryAcquire(arg)) {
                	 /**
                	  * 只有在当前结点的前继结点为head时，当前结点去才会尝试获取锁。
                	  * 获取锁成功时（tryAcquire返回true），将当前结点设置成head，
                	  * 并根据中断状态返回true或者false。
                	  */
                    setHead(node);
                    p.next = null; // help GC
                    failed = false;
                    return interrupted;
                }
                
                /**
                 * shouldParkAfterFailedAcquire判断是否应该阻塞（park）当前线程，判断的依据是
                 * 前继结点的状态（p.waitStatus），只有该状态为Node.SIGNAL时才会阻塞当前线程：
                 * 此状态说明，当前结点无法暂时获取锁，并且前继结点保证会在释放锁的时候唤醒当前线程。
                 *
                 * parkAndCheckInterrupt的实现就比较简单了，调用LockSupport.park(this)阻塞
                 * 当前线程，并返回线程当前的中断状态。
                 */
                if (shouldParkAfterFailedAcquire(p, node) &&
                    parkAndCheckInterrupt())
                    interrupted = true;
            }
        } finally {
            if (failed)
                cancelAcquire(node);
        }
    }
</pre>

####release：互斥锁的释放

<pre class="prettyprint linenums:1259 lang-java">
    public final boolean release(int arg) {
        if (tryRelease(arg)) {
            Node h = head;
            if (h != null && h.waitStatus != 0)
                /**
                 * 在head不为null，并且waitStatus不为0的情况下，唤醒后继结点：只是给后续结点一次
                 * 竞争锁的机会，后续结点未必能获取到锁。 
                 *
                 * unparkSuccessor的实现：找到h的后继结点，并调用LockSupport.unpark唤醒后继结点
                 * 对应的线程。
                 */
                unparkSuccessor(h);
            return true;
        }
        return false;
    }
</pre>

####acquireShared：共享锁获取

<pre class="prettyprint linenums:946 lang-java">
    public final void acquireShared(int arg) {
        /**
         * 调用具体实现类的tryAcquireShared，如果返回值不小于0，则认为获取共享锁成功；
         * 否则通过doAcquireShared调用进入等待锁逻辑。
         */
        if (tryAcquireShared(arg) < 0)
            doAcquireShared(arg);
    }
</pre>

<pre class="prettyprint linenums:946 lang-java">
    private void doAcquireShared(int arg) {
        final Node node = addWaiter(Node.SHARED);
        boolean failed = true;
        try {
            boolean interrupted = false;
            for (;;) {
                final Node p = node.predecessor();
                if (p == head) {
                    int r = tryAcquireShared(arg);
                    if (r >= 0) {
                        /**
                         * 仔细与上面的互斥锁的获取逻辑比较下，会发现逻辑基本差不多：
                         * 前继结点为head，并且获取锁成功（与互斥锁不同的时tryAcquireShared返回值
                         * 不小于0时，认为获取锁成功）；不但要将当前结点设置为head结点，并且要将此事件
                         * 向后传递（setHeadAndPropagate）。
                         */
                        setHeadAndPropagate(node, r);
                        p.next = null; // help GC
                        if (interrupted)
                            selfInterrupt();
                        failed = false;
                        return;
                    }
                }
                
                /**
                 * 与互斥锁逻辑一致
                 */
                if (shouldParkAfterFailedAcquire(p, node) &&
                    parkAndCheckInterrupt())
                    interrupted = true;
            }
        } finally {
            if (failed)
                cancelAcquire(node);
        }
    }
</pre>

<pre class="prettyprint linenums:708 lang-java">
    private void setHeadAndPropagate(Node node, int propagate) {
        Node h = head; // Record old head for check below
        setHead(node);
        /*
         * Try to signal next queued node if:
         *   Propagation was indicated by caller,
         *     or was recorded (as h.waitStatus) by a previous operation
         *     (note: this uses sign-check of waitStatus because
         *      PROPAGATE status may transition to SIGNAL.)
         * and
         *   The next node is waiting in shared mode,
         *     or we don't know, because it appears null
         *
         * The conservatism in both of these checks may cause
         * unnecessary wake-ups, but only when there are multiple
         * racing acquires/releases, so most need signals now or soon
         * anyway.
         */
        if (propagate > 0 || h == null || h.waitStatus < 0) {
            Node s = node.next;
            if (s == null || s.isShared())
                doReleaseShared();
        }
    }
</pre>

setHeadAndPropagate除了将head设置为当前持有锁的结点外，还需要保证在后面这两种情况下向后传播可以获取锁的信息：
> 1. propagate > 0（也就是tryAcquireShared > 0，表示后续的获取锁操作也可能成功）；
> 2. 原始head结点的waitStatus < 0，也就是以前有某个结点希望释放锁的操作向后传播。

####releaseShared：共享锁的释放

<pre class="prettyprint linenums:1339 lang-java">
    public final boolean releaseShared(int arg) {
        if (tryReleaseShared(arg)) {
            doReleaseShared();
            return true;
        }
        return false;
    }
</pre>

<pre class="prettyprint linenums:670 lang-java">
    private void doReleaseShared() {
        for (;;) {
            Node h = head;
            if (h != null && h != tail) {
                int ws = h.waitStatus;
                if (ws == Node.SIGNAL) {
                    if (!compareAndSetWaitStatus(h, Node.SIGNAL, 0))
                        continue;            // loop to recheck cases
                    unparkSuccessor(h);
                }
                else if (ws == 0 &&
                         !compareAndSetWaitStatus(h, 0, Node.PROPAGATE))
                    continue;                // loop on failed CAS
            }
            if (h == head)                   // loop if head changed
                break;
        }
    }
</pre>

可以看到，doReleaseShared需要保证两点：
> 1. 要么至少唤醒一个等待的结点：waitStatus == Node.SIGNAL；
> 2. 要么将当前head结点的waitStatus设置成Node.PROPAGATE，以保证在后续线程持有到锁后，可以向后传播此次释放锁事件（见setHeadAndPropagate的分析）。
      
##具体锁实现

###ReentrantLock

互斥模式，state代表互斥锁的状态：为0说明当前锁可用；为1说明当前锁已经被某个线程持有，其它线程必须等待。获取锁等价于将state设置成1；释放锁等价于将state设置为0。

####公平锁获取

<pre class="prettyprint linenums:236 lang-java">
        protected final boolean tryAcquire(int acquires) {
            final Thread current = Thread.currentThread();
            int c = getState();
            if (c == 0) {
                if (!hasQueuedPredecessors() &&
                    compareAndSetState(0, acquires)) {
                    /**
                     * 只有在等待队列里没有前继等待线程时（!hasQueuedPredecessors），
                     * 当前线程才能尝试获取锁（更新锁状态：compareAndSetState(0, acquires)），
                     * 如果成功则将当前线程标记为锁持有者，并且返回true。
                     */
                    setExclusiveOwnerThread(current);
                    return true;
                }
            }
            else if (current == getExclusiveOwnerThread()) {
                /**
                 * 处理重入逻辑：当前线程持有锁，并且又发起获取锁请求
                 */
                int nextc = c + acquires;
                if (nextc < 0)
                    throw new Error("Maximum lock count exceeded");
                setState(nextc);
                return true;
            }
            return false;
        }
</pre>

####非公平锁获取

<pre class="prettyprint linenums:217 lang-java">
        protected final boolean tryAcquire(int acquires) {
            return nonfairTryAcquire(acquires);
        }
</pre>
        
<pre class="prettyprint linenums:133 lang-java">
        final boolean nonfairTryAcquire(int acquires) {
            final Thread current = Thread.currentThread();
            int c = getState();
            if (c == 0) {
                /**
                 * 跟公平锁获取相比，这里没有判断是否有前继等待线程。也就是说当前线程可以在等待队列里
                 * 有线程在等待获取锁的时候，竞争成功并且持有锁，这对其它等待线程来说，就是不公平的。
                 */
                if (compareAndSetState(0, acquires)) {
                    setExclusiveOwnerThread(current);
                    return true;
                }
            }
            else if (current == getExclusiveOwnerThread()) {
                int nextc = c + acquires;
                if (nextc < 0) // overflow
                    throw new Error("Maximum lock count exceeded");
                setState(nextc);
                return true;
            }
            return false;
        }
</pre>

###ReentrantReadWriteLock

共享互斥模式结合：写锁对应互斥锁，读锁对应共享锁。state被分为两部分：高16位代表读锁持有数量；低16位代表写锁持有数量。

主要的实现逻辑跟ReentrantLock类似，但因为同时有两个锁，所以有些不同：

> 1. 在写锁被当前线程持有的情况下，其它线程不同持有任意锁；
> 2. 在写锁被当前线程持有的情况下，当前线程可以继续请求获取读锁和写锁；
> 3. 在读锁被当前线程持有的情况下，其它线程可以持有读锁，不能持有写锁；
> 4. 在读锁被当前线程持有的情况下，当前线程和其它持有读锁的线程可以继续请求获取读锁，不能请求获取写锁。

代码就不详细说明了。

###Semaphore

共享模式，state代表许可的个数，初始为许可的个数，每一次的acquire，许可减1。注意：tryAcquireShared返回为int，这里会返回剩余的许可个数。

公平与非公平的处理与ReentrantLock处理逻辑类似，不再详细分析。

###CountDownLatch

共享模式，state代表count个数，初始为count个数。下面为核心代码：

<pre class="prettyprint linenums:177 lang-java">
        protected int tryAcquireShared(int acquires) {
            return (getState() == 0) ? 1 : -1;
        }

        protected boolean tryReleaseShared(int releases) {
            // Decrement count; signal when transition to zero
            for (;;) {
                int c = getState();
                if (c == 0)
                    return false;
                int nextc = c-1;
                if (compareAndSetState(c, nextc))
                    return nextc == 0;
            }
        }
</pre>

可以看到，在初始情况下，所有的tryAcquireShared（CountDownLatch.await会调用此方法）都会阻塞（getState == count，不为0）；每一次的tryReleaseShared（CountDownLatch.countDown会调用此方法）将count减1，直到为0并且会返回true（nextc == 0），这时acquireShared会调用doReleaseShared唤醒被阻塞的线程（这时getState == 0）。

###FutureTask

共享模式，state代表任务的完成状态：0代表任务已经准备就绪，1代表任务正在运行，2代表任务已经完成，4代表任务取消。

<pre class="prettyprint linenums:223 lang-java">
        /**
         * Implements AQS base acquire to succeed if ran or cancelled
         */
        protected int tryAcquireShared(int ignore) {
            return innerIsDone() ? 1 : -1;
        }

        /**
         * Implements AQS base release to always signal after setting
         * final done status by nulling runner thread.
         */
        protected boolean tryReleaseShared(int ignore) {
            runner = null;
            return true;
        }
</pre>

由上面代码可以看到在任务没有完成时，任何调用tryAcquireShared（FutureTask.get会调用此方法）的线程都会阻塞；tryReleaseShared永远返回true。

任务执行完成后，会将state设置成2（正常完成或者出现异常）或者4（任务被取消）：innerIsDone方法在这两种情况下都会返回true。


[aqs]: http://gee.cs.oswego.edu/dl/papers/aqs.pdf "The java.util.concurrent Synchronizer Framework"
[locksuport]: http://whitesock.iteye.com/blog/1336409 "Inside AbstractQueuedSynchronizer (1)"