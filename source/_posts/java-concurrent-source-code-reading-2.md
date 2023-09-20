---
title: "Java并发源码分析 - ThreadPoolExecutor"
date: 2013-09-13 14:32
comments: true
toc: true
categories: 
    - Java 
    - Concurrent 
tags:
    - java
    - concurrent
---
## 为什么需要线程池？
> 1. 避免在运行大量任务时，频繁的线程创建和销毁开销；
> 2. 使资源的使用得到有效控制，避免创建过多的线程占用系统资源。

<!--more-->

## 基本概念
### Core and maximum pool sizes
控制线程池核心线程数以及最大可生成的线程数量。是否需要创建线程与当前线程的数量以及任务队列的状态在关，后面会详述。

<h3 id="timeout">Keep-alive times</h3>
默认情况下，只有在当前worker线程数大于core大小的情况下，空闲一定时间的worker线程才可以被回收，但是也可以通过allowCoreThreadTimeOut(boolean)函数来控制core线程的超时时间。

### 任务队列
ThreadPoolExecutor使用BlockingQueue来管理任务队列，任务队列与线程池大小的关系如下：
> * 如果线程池数量小于corePoolSize，Executor倾向于新增worker线程；
> * 如果线程池数量多于或者等于corePoolSize倾向于将任务放入队列；
> * 如果任务队列已满，并且线程池数量还没有超过maximumPoolSize，那么新的worker线程；
> * 如果任务队列已满，并且线程池数量已经超过maximumPoolSize，那么任务被reject；

## 实现
### 提交任务

{% codeblock lang:java first_line:1300 %}
    public void execute(Runnable command) {
        if (command == null)
            throw new NullPointerException();

        int c = ctl.get();
        if (workerCountOf(c) < corePoolSize) {
            /**
             * 如果当前worker数量小于corePoolSize，则创建新的worker。
             */
            if (addWorker(command, true))
                return;
            c = ctl.get();
        }
        
        /**
         * 尝试将任务添加到任务队列。
         */
        if (isRunning(c) && workQueue.offer(command)) {
            int recheck = ctl.get();
            if (! isRunning(recheck) && remove(command))
                reject(command);
            else if (workerCountOf(recheck) == 0)
                addWorker(null, false);
        }
        /**
         * 在worker数量大于corePoolSize，并且任务添加到队列失败（队列满）的情况下，尝试创建新的worker，
         * 如果创建失败表示已经达到maximumPoolSize，则reject任务。
         */
        else if (!addWorker(command, false))
            reject(command);
    }
{% endcodeblock %}

### 创建worker线程

去除一些状态检查后，核心代码如下：

{% codeblock lang:java first_line:886 %}
    private boolean addWorker(Runnable firstTask, boolean core) {
        Worker w = new Worker(firstTask);
        Thread t = w.thread;

        final ReentrantLock mainLock = this.mainLock;
        mainLock.lock();
        try {
            workers.add(w);

            int s = workers.size();
            if (s > largestPoolSize)
                largestPoolSize = s;
        } finally {
            mainLock.unlock();
        }

        t.start();

        return true;
    }
{% endcodeblock %}

可以看到，很简单，创建一个Worker线程，将他加到workers集合中，然后启动对应worker线程，DONE。

我们来看看Worker的定义：

{% codeblock lang:java first_line:575 %}
    private final class Worker
        extends AbstractQueuedSynchronizer
        implements Runnable
    {
        /**
         * This class will never be serialized, but we provide a
         * serialVersionUID to suppress a javac warning.
         */
        private static final long serialVersionUID = 6138294804551838833L;

        /** Thread this worker is running in.  Null if factory fails. */
        final Thread thread;
        /** Initial task to run.  Possibly null. */
        Runnable firstTask;
        /** Per-thread task counter */
        volatile long completedTasks;

        /**
         * Creates with given first task and thread from ThreadFactory.
         * @param firstTask the first task (null if none)
         */
        Worker(Runnable firstTask) {
            this.firstTask = firstTask;
            this.thread = getThreadFactory().newThread(this);
        }

        /** Delegates main run loop to outer runWorker  */
        public void run() {
            runWorker(this);
        }

        // Lock methods
        //
        // The value 0 represents the unlocked state.
        // The value 1 represents the locked state.

        protected boolean isHeldExclusively() {
            return getState() == 1;
        }

        protected boolean tryAcquire(int unused) {
            if (compareAndSetState(0, 1)) {
                setExclusiveOwnerThread(Thread.currentThread());
                return true;
            }
            return false;
        }

        protected boolean tryRelease(int unused) {
            setExclusiveOwnerThread(null);
            setState(0);
            return true;
        }

        public void lock()        { acquire(1); }
        public boolean tryLock()  { return tryAcquire(1); }
        public void unlock()      { release(1); }
        public boolean isLocked() { return isHeldExclusively(); }
    }
{% endcodeblock %}

除去跟锁定义相关的代码后，核心就是run函数的实现：调用runWorker运行Worker线程的运行逻辑。

### Worker线程运行逻辑

{% codeblock lang:java first_line:1098 %}
    final void runWorker(Worker w) {
        Runnable task = w.firstTask;
        w.firstTask = null;
        boolean completedAbruptly = true;
        try {
            while (task != null || (task = getTask()) != null) {
                w.lock();
                clearInterruptsForTaskRun();
                try {
                    beforeExecute(w.thread, task);
                    Throwable thrown = null;
                    try {
                        task.run();
                    } catch (RuntimeException x) {
                        thrown = x; throw x;
                    } catch (Error x) {
                        thrown = x; throw x;
                    } catch (Throwable x) {
                        thrown = x; throw new Error(x);
                    } finally {
                        afterExecute(task, thrown);
                    }
                } finally {
                    task = null;
                    w.completedTasks++;
                    w.unlock();
                }
            }
            completedAbruptly = false;
        } finally {
            processWorkerExit(w, completedAbruptly);
        }
    }
{% endcodeblock %}

就是一个while循环，在有任务的情况下（两种：一种在创建Worker线程时传入，由firtstTask传入；一种通过getTask由任务队列获取），执行任务，并调用设置的回调函数（beforeExecute，afterExecute等）。

我们来看看getTask的实现：

{% codeblock lang:java first_line:1098 %}
    private Runnable getTask() {
        boolean timedOut = false; // Did the last poll() time out?
        for (;;) {
            try {
                Runnable r = timed ?
                    workQueue.poll(keepAliveTime, TimeUnit.NANOSECONDS) :
                    workQueue.take();
                if (r != null)
                    return r;
                timedOut = true;
            } catch (InterruptedException retry) {
                timedOut = false;
            }
        }
    }
{% endcodeblock %}

去除了状态检查的相关代码后，核心的逻辑如下：在需要处理[超时](#timeout)的情况下调用BlockingQueue.poll来获取任务，如果在超时后还没有任务，则让相应的worker线程退出；如果不需要处理超时时候，调用BlockingQueue.take，阻塞当前worker线程一直到有任务到达。

### 总结

ThreadPoolExecutor会根据线程池状态和任务队列状态创建worker线程，而每个worker线程的主要任务就是不断的去任务队列里去拿任务：要么一直阻塞等，要么超时后退出；拿到任务后，运行任务并调用相关回调。
