---
title: "Java并发源码分析 - ForkJoin框架"
date: 2013-09-17 23:04
comments: true
toc: true
categories: 
    - Java
tags:
    - java
    - concurrent
---
## 功能
根据Java文档描述，ForkJoinPool中一种特殊的ExecutorService，可以执行ForkJoinTask。ForJoinTask可以在运行时Fork子任务，并join子任务的完成，本质上类似分治算法：将问题尽可能的分割，直到问题可以快速解决。对ForkJoinPool来说，与其它ExecutorService最重要的不同点是，它的工作线程会从其它工作线程的任务队列偷任务来执行。

<!--more-->

## 实现
根据代码里的文档，可以了解到ForkJoin框架主要由三个类组成：
> * ForkJoinPool：管理worker线程，类似ThreadPoolExecutor，提供接口用于提交或者执行任务；
> * ForkJoinWorkerThread：worker线程，任务保存在一个deque中；
> * ForkJoinTask<V>：ForkJoin框架中运行的任务，可以fork子任务，可以join子任务完成。

### 任务队列的管理

ForkJoinPool及ForkJoinWorkerThread都有维护一个任务队列，ForkJoinPool用这个队列来保存非worker线程提交的任务，而ForkJoinWorkerThread则保存提交到本worker线程的任务。

任务队列以deque的形式存在，不过只通过三种方式访问其中的元素：push，pop，deq，其中push和pop只会由持有该队列的线程访问，而deq操作则是否由其它worker线程来访问。对应到代码上则是：
> * ForkJoinTask<?>[] queue：代表任务队列，环形数组；
> * int queueTop：队列头，push或者pop操作时，修改此值，因为只会被当前worker线程访问，所以是普通变量；
> * volatile int queueBase：队列尾部，deq操作时修改此值，会有多个线程访问，使用volatile。

#### 数据元素访问

{% codeblock lang:java %}
long u = (((s = queueTop) & (m = q.length - 1)) << ASHIFT) + ABASE;
UNSAFE.putOrderedObject(q, u, t);
queueTop = s + 1;         // or use putOrderedInt
{% endcodeblock %}

上面的代码是从入队操作中的一段，前文提到queueTop保存队列头，那为什么不直接用queue[queueTop]=t来赋值就行了？了解原因之前，先来看看这两行代码在做什么：

{% codeblock lang:java %}
(s = queueTop) & (m = q.length - 1) // queueTop % (q.length - 1)，也就是queueTop根据队列长度取模，
									 // 取模后，就是队列头实际在数组中的索引；
{% endcodeblock %}

那 Index << ASHIFT + ABASE在算什么？先看看ASHIFT及ABASE的定义：

{% codeblock lang:java first_line:983 %}
    static {
        int s;
        try {
            UNSAFE = sun.misc.Unsafe.getUnsafe();
            Class a = ForkJoinTask[].class;
            ABASE = UNSAFE.arrayBaseOffset(a);
            s = UNSAFE.arrayIndexScale(a);
        } catch (Exception e) {
            throw new Error(e);
        }
        if ((s & (s-1)) != 0)
            throw new Error("data type scale not a power of two");
        ASHIFT = 31 - Integer.numberOfLeadingZeros(s);
    }
{% endcodeblock %}

再来看看UNSAFE.arrayBaseOffset及UNSAFE.arrayIndexScale的文档：
> public native int arrayBaseOffset(Class arrayClass)
> 
> Report the offset of the first element in the storage allocation of a
> given array class.  If #arrayIndexScale  returns a non-zero value
> for the same class, you may use that scale factor, together with this
> base offset, to form new offsets to access elements of arrays of the
> given class.
> 
> public native int arrayIndexScale(Class arrayClass)
> 
> Report the scale factor for addressing elements in the storage
> allocation of a given array class.  However, arrays of "narrow" types
> will generally not work properly with accessors like #getByte(Object, int) , so the scale > > factor for such classes is reported as zero.

Java数组在实际存储时有一个对象头，后面才是实际的数组数据，而UNSAFE.arrayBaseOffset就是用来获取实际数组数据的偏移量；UNSAFE.arrayIndexScale则是获取对应数组元素占的字节数。这里的代码ABASE=16（数组对象头大小），s=4（ForkJoinTask对象引用占用字节数），ASIFT=2。

所以上面的Index << ASHIFT + ABASE合起来就是Index左移2位=Index*4，也就是算Index的在数组中的偏移量，再加上ABASE就是Index在对象中的偏移量。也就是那一行代码主要就是算出来queueTop在队列数组中的实际偏移量，知道了这些，我们再来看第二行代码：

{% codeblock lang:java %}
UNSAFE.putOrderedObject(q, u, t);
{% endcodeblock %}

UNSAFE.putOrderedObject的文档：
> public native  void putOrderedObject(Object o,long offset, Object x)
>
> Version of #putObjectVolatile(Object, long, Object) 
> that does not guarantee immediate visibility of the store to
> other threads. This method is generally only useful if the
> underlying field is a Java volatile (or if an array cell, one
> hat is otherwise only accessed using volatile accesses).

看的不明不白，找了下资料，[这篇文章](http://robsjava.blogspot.com/2013/06/a-faster-volatile.html)及[这里](http://bugs.sun.com/bugdatabase/view_bug.do?bug_id=6275329)解释的比较清楚：
> Unsafe.putOrderedObject guarante that writes will not be re-orderd by instruction 
> reordering. Under the covers it uses the faster store-store barrier, rather than the the 
> slower store-load barrier, which is used when doing a volatile write.
>
> write may be reordered with subsequent operations (or equivalently, might not be visible to 
> other threads) until some other volatile write or synchronizing action occurs)


也就是说能够保证写写不会被重排序，但是不保证写会对其它线程可见，而volatile既保证写写不会被重排序，也保证写后对其它线程立即可见。可见Unsafe.putOrderedObject会比直接的volatile变量赋值速度会一点，[这篇文章](http://robsjava.blogspot.com/2013/06/a-faster-volatile.html)则指出Unsafe.putOrderedObject会比volatile写快3倍。

了解清楚这两行代码的作用后，再来回答一开始提出的问题，为什么要这么用？结合代码中的文档及自己的理解，我觉得原因无非两点：
> * 需要保证写入元素的顺序对其它worker线程一致，也就是不会产生写写重排序；
> * 不需要保证写读是否重排序，因为如果其它worker线程需要从当前队列steal任务，那么首先必须得个性volatile字段
> queueBase，而volatile的语义保证读之前的所有写操作的可见性，而Unsafe.putOrderedObject性能明显要好于
> volatile写。

**不知道上面的理解是否正确，如有问题，请指正**。

好吧，两行代码包含这么多的知识点。

#### 容量

初始容量 1<<13，最大容量 1<<24，队列满时，以2倍的方式增长，所以容量一直是2的幂次方。下面是扩容时的代码：

{% codeblock lang:java first_line:477 %}
    /**
     * Creates or doubles queue array.  Transfers elements by
     * emulating steals (deqs) from old array and placing, oldest
     * first, into new array.
     */
    private void growQueue() {
        ForkJoinTask<?>[] oldQ = queue;
        int size = oldQ != null ? oldQ.length << 1 : INITIAL_QUEUE_CAPACITY;
        if (size > MAXIMUM_QUEUE_CAPACITY)
            throw new RejectedExecutionException("Queue capacity exceeded");
        if (size < INITIAL_QUEUE_CAPACITY)
            size = INITIAL_QUEUE_CAPACITY;
        ForkJoinTask<?>[] q = queue = new ForkJoinTask<?>[size];
        int mask = size - 1;
        int top = queueTop;
        int oldMask;
        if (oldQ != null && (oldMask = oldQ.length - 1) >= 0) {
            for (int b = queueBase; b != top; ++b) {
                long u = ((b & oldMask) << ASHIFT) + ABASE;
                Object x = UNSAFE.getObjectVolatile(oldQ, u);
                if (x != null && UNSAFE.compareAndSwapObject(oldQ, u, x, null))
                    UNSAFE.putObjectVolatile
                        (q, ((b & mask) << ASHIFT) + ABASE, x);
            }
        }
    }
{% endcodeblock %}

有了开始的分析，这段代码就比较容易理解了：
> 1. 从queueBase开始直到queueTop，通过UNSAFE.getObjectVolatile读取对应位置的元素；
> 2. 通过UNSAFE.compareAndSwapObject将对应位置的元素设置为null；
> 3. 如果上述CAS成功，则通过UNSAFE.putObjectVolatile将该元素写入到新的队列；

#### 入队

{% codeblock lang:java first_line:459 %}
    final void pushTask(ForkJoinTask<?> t) {
        ForkJoinTask<?>[] q; int s, m;
        if ((q = queue) != null) {    // ignore if queue removed
            long u = (((s = queueTop) & (m = q.length - 1)) << ASHIFT) + ABASE;
            UNSAFE.putOrderedObject(q, u, t);
            queueTop = s + 1;         // or use putOrderedInt
            if ((s -= queueBase) <= 2)
                pool.signalWork();
            else if (s == m) 
                growQueue();
        }
    }
{% endcodeblock %}

如果队列中的任务数大于2，则通知线程池唤醒或者创建一个worker线程；如果队列已经满了（s == m），则通过growQueue对队列进行扩容。

#### 出队

出队分两种，一种从队列头部出队（当前worker线程），别一种从队列尾部出队（其它worker线程）。

**从队列头部出队：**

{% codeblock lang:java first_line:546 %}
    private ForkJoinTask<?> popTask() {
        int m;
        ForkJoinTask<?>[] q = queue;
        if (q != null && (m = q.length - 1) >= 0) {
            for (int s; (s = queueTop) != queueBase;) {
                int i = m & --s;
                long u = (i << ASHIFT) + ABASE; // raw offset
                ForkJoinTask<?> t = q[i];
                if (t == null)   // lost to stealer
                    break;
                if (UNSAFE.compareAndSwapObject(q, u, t, null)) {
                    queueTop = s; // or putOrderedInt
                    return t;
                }
            }
        }
        return null;
    }
{% endcodeblock %}

主要逻辑如下：
> 1. 在队列不为空的情况下，从queueTop - 1位置处读取元素；
> 2. 如果元素不为null，则通过UNSAFE.compareAndSwapObject将queueBase对应的元素置为null；
> 3. 如果上述CAS成功，将该元素返回，并将queueTop减1；如果CAS失败，则重试。

**从队列尾部出队：**

{% codeblock lang:java first_line:506 %}
    final ForkJoinTask<?> deqTask() {
        ForkJoinTask<?> t; ForkJoinTask<?>[] q; int b, i;
        if (queueTop != (b = queueBase) &&
            (q = queue) != null && // must read q after b
            (i = (q.length - 1) & b) >= 0 &&
            (t = q[i]) != null && queueBase == b &&
            UNSAFE.compareAndSwapObject(q, (i << ASHIFT) + ABASE, t, null)) {
            queueBase = b + 1;
            return t;
        }
        return null;
    }
{% endcodeblock %}

主要逻辑如下：
> 1. 在队列不为空，并且queueBase对应位置的元素不为null，从queueBase读取元素；
> 2. 通过UNSAFE.compareAndSwapObject将queueBase对应的元素置为null；
> 3. 如果上述CAS成功，将queueBase位置对应的元素返回，并将queueBase加1。

### 提交任务

ForkJoinPool提供了类似ThreadPoolExecutor的接口来提供普通任务或者ForkJoinTask，这些接口最终都会调用forkOrSubmit来完成任务提交：

{% codeblock lang:java first_line:1529 %}
    private <T> void forkOrSubmit(ForkJoinTask<T> task) {
        ForkJoinWorkerThread w;
        Thread t = Thread.currentThread();
        if (shutdown)
            throw new RejectedExecutionException();
        if ((t instanceof ForkJoinWorkerThread) &&
            (w = (ForkJoinWorkerThread)t).pool == this)
            w.pushTask(task);
        else
            addSubmission(task);
    }
{% endcodeblock %}

可以看到，forkOrSubmit要么将任务提交到对应worker线程的任务队列（提交任务的线程本身就是worker线程，并且该worker线程属于当前ForkJoinPool，通过w.pushTask提交任务，前文已分析过），要么将任务提交到ForkJoinPool提供的任务队列。

看一下addSubmission的实现：

{% codeblock lang:java first_line:1529 %}
    private void addSubmission(ForkJoinTask<?> t) {
        final ReentrantLock lock = this.submissionLock;
        lock.lock();
        try {
            ForkJoinTask<?>[] q; int s, m;
            if ((q = submissionQueue) != null) {    // ignore if queue removed
                long u = (((s = queueTop) & (m = q.length-1)) << ASHIFT)+ABASE;
                UNSAFE.putOrderedObject(q, u, t);
                queueTop = s + 1;
                if (s - queueBase == m)
                    growSubmissionQueue();
            }
        } finally {
            lock.unlock();
        }
        signalWork();
    }
{% endcodeblock %}

基本逻辑跟pushTask一致，只不过多加了个锁（同一时间，可能会有多个外部线程提交任务），并且是每加一个任务就会调用singalWork。

### fork子任务

也就是当前任务fork一个子任务，看一下实现：

{% codeblock lang:java first_line:621 %}
    public final ForkJoinTask<V> fork() {
        ((ForkJoinWorkerThread) Thread.currentThread())
            .pushTask(this);
        return this;
    }
{% endcodeblock %}

比较简单，就是将任务提交到当前worker线程的任务队列。

### join子任务

等待子任务的完成：

{% codeblock lang:java first_line:638 %}
    public final V join() {
        if (doJoin() != NORMAL)
            return reportResult();
        else
            return getRawResult();
    }
{% endcodeblock %}

{% codeblock lang:java first_line:348 %}
    private int doJoin() {
        Thread t; ForkJoinWorkerThread w; int s; boolean completed;
        if ((t = Thread.currentThread()) instanceof ForkJoinWorkerThread) {
            if ((s = status) < 0)
                return s;
            if ((w = (ForkJoinWorkerThread)t).unpushTask(this)) {
            	/**
            	 * unpushTask与上面分析的popTask实现类似，只是多了个判断，队列头的任务是不是当前任务。
            	 * 也就是说，当join任务时，如果当前任务就在队列头部，就直接在当前worker线程执行。
            	 */
                try {
                    completed = exec();
                } catch (Throwable rex) {
                    return setExceptionalCompletion(rex);
                }
                if (completed)
                    return setCompletion(NORMAL);
            }
            
            /**
             * 任务不在队列头部，调用joinTask等待任务完成。
             */
            return w.joinTask(this);
        }
        else
        	/**
        	 * 不是worker线程，直接调用Object.wait等待任务完成。
        	 */
            return externalAwaitDone();
    }
{% endcodeblock %}

我们来看一下joinTask的实现：

{% codeblock lang:java first_line:708 %}
    final int joinTask(ForkJoinTask<?> joinMe) {
        ForkJoinTask<?> prevJoin = currentJoin;
        currentJoin = joinMe;
        for (int s, retries = MAX_HELP;;) {
            if ((s = joinMe.status) < 0) {
                currentJoin = prevJoin;
                return s;
            }
            if (retries > 0) {
                if (queueTop != queueBase) {
                    if (!localHelpJoinTask(joinMe))
                        retries = 0;           // cannot help
                }
                else if (retries == MAX_HELP >>> 1) {
                    --retries;                 // check uncommon case
                    if (tryDeqAndExec(joinMe) >= 0)
                        Thread.yield();        // for politeness
                }
                else
                    retries = helpJoinTask(joinMe) ? MAX_HELP : retries - 1;
            }
            else {
                retries = MAX_HELP;           // restart if not done
                pool.tryAwaitJoin(joinMe);
            }
        }
    }
{% endcodeblock %}

主要流程：
> 1. localHelpJoinTask：如果当前工作线程的任务队列不为空，则尝试在当前线程执行一个任务（未必是要join的任务）；但是如果任务队列的头部已经有一个任务在等待任务完成，则通过Object.wait等待任务完成；
> 2. tryDeqAndExec：如果要join的任务在某个工作线程任务队列的尾部，则直接把任务偷取过来并执行；
> 3. helpJoinTask：找到偷取当前任务的工作线程，并从其队列尾部偷取一个任务执行；如果该工作线程也在等待一个任务完成，则继续递归寻找偷取该任务的工作线程。

### 偷取任务

偷取任务的逻辑很简单，就是从其它工作线程的队列尾部（queueBase）出队一个任务，并在当前工作线程中执行。可以看一下helpJoinTask中的一段代码：

{% codeblock lang:java first_line:806 %}
	if (t != null && v.queueBase == b &&
		UNSAFE.compareAndSwapObject(q, u, t, null)) { // 获取到队列尾部的任务，通过CAS将队列中对应位置设为null
		v.queueBase = b + 1; // 更新queueBase
		v.stealHint = poolIndex; // 将stealHint设为当前工作线程
		ForkJoinTask<?> ps = currentSteal;
		currentSteal = t;
		t.doExec(); // 在当前工作线程中执行偷取到的任务
		currentSteal = ps;
		helped = true;
	}
{% endcodeblock %}
