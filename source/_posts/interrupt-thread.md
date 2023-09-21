---
title: 中断线程的执行
date: 2011-11-21 21:37:16
comments: true
toc: true
categories: 
    - Java
tags:
    - java
    - concurrent
---

中断线程是指：线程正在运行，还没有正常退出（run方法顺利结束），而某个事件的发生导致该线程必须中断当前正在执行的任务，该线程或者退出，或者等待其它事件然后再继续执行。稳定的基于线程的服务，在程序退出时，必须能够安全的释放线程所占用的资源，减少对系统性能的影响。

<!--more-->

Thread类提供的方法中与此功能相关的函数有Thread.stop，Thread.suspend，Thread.resume。但是这几个函数都不能安全的提供相应的功能：Thread.stop会导致对象处理不一致的状态，而Thread.suspend和Thread.resume则会导致出现死锁，具体可见API文档描述。

虽然Thread类没有一种直接又安全的机制中断线程的执行，但是却提供了一种协作机制来完成类似的功能：Thread.interrupt。但是，别误解，单纯调用这个函数并不能完成我们定义的中断线程的功能，很多时候，它只是在线程内部设置一个状态位，表示当前线程收到过interrupt请求。在解释Thread.interrupt之前，我们先看一下，如果没有相关机制的支持，我们自己怎样完成中断线程执行的功能（这里不区分Runnable和Thread；这个机制要正常工作，volatile关键字不能缺）：

{% codeblock lang:java %}
class CancellableTask1 implements Runnable {
    private volatile boolean cancelled = false;
    @Override
    public void run() {
        while (!cancelled) {
            doSomething();
        }
    }
    public void cancel() { cancelled = true; };
}
{% endcodeblock %}

现在考虑一个问题，如果doSomething中执行一个长时间阻塞的操作（比如sleep），那会发生什么情况？这个线程要么等待长时间（取决于阻塞操作等待的时间）后退出，要么一直不会退出（阻塞操作等待的事件没有发生）。这时候，Thread.interrupt就会发挥作用，来看一下它的API描述（原文比较详细，这里只是大致总结）：
1. 如果当前线程处于阻塞状态（部分阻塞操作，一般情况下指可抛出InterruptedException的操作，如Thread.sleep），那么调用Thread.interrupt，该线程会收到一个InterruptedException，并且将当前线程的中断状态清除；
2. 如果当前线程没有阻塞，那么调用Thread.interrupt后，当前线程的中断状态被设置成true。
看描述Thread.interrupt是不能直接完成中断线程的目的，所以才说它是一种协作机制。我们来看一下这种协作机制在操作阻塞时完成中断线程的目标：

{% codeblock lang:java %}
class CancellableTask2 implements Runnable {
    @Override
    public void run() {
        try {
            while (true) {
                doSomething();
            }
        } catch (InterruptedException e) {
            // Exit thread, or do something before exit.
            // Preserve interrupt status
            Thread.currentThread().interrupt();
        }
    }
    public void cancel() { Thread.currentThread().interrupt(); 
}
{% endcodeblock %}

这种方式下，如果有interrupt请求，线程会立即退出，当然，Thread.interrupt调用并没有强制线程一定要对interrupt请求作出响应，也可以忽略请求，继续运行（如CancellableTask3），这就取决于线程创建者采取的响应策略。只有清楚一个线程的响应策略时，才能利用Thread.interrupt机制来中断线程运行。

{% codeblock lang:java %}
class CancellableTask3 implements Runnable {
    @Override
    public void run() {
        while (!Thread.currentThread().isInterrupted()) {
            try {
                doSomething();
            } catch (InterruptedException e) {
                // Continue
            }
        }
    }
    public void cancel() { Thread.currentThread().interrupt(); }
}
{% endcodeblock %}

前面说明Thread.interrupt的作用时提到，只有部分阻塞操作会对interrupt请求作出响应抛出InterruptedException，那对interrupt请求无响应的操作，该怎么处理？如跟Socket读写相关的InputStream，OutputStream的read和write操作都不会interrupt请求作出响应，但是关闭底层的Socket是导致read和write操作招聘SocketException，所以也可以作为一种中断线程的方式。

JDK1.5后，Java中提供java.util.concurrent包，其中包含了若干跟并发和线程管理相关的功能。ThreadPoolExecutor.submit就可以通过返回一个Future来取消或中断当前任务的执行，Future底层的实现机制也是通过Thread.interrupt来实现的。
Future.cancel只能中断对interrupt请求有响应的操作，如果阻塞的操作对interrupt请求无响应怎么办？那么可以通过重写ThreadPoolExecutor.newTaskFor（JDK1.6）来返回自定义的Future.cancel来实现。

当然， Thread.interrupt机制要实现类似Thread.suspend、Thread.resume提供的暂停和继续的语义可能比较麻烦，不过，JDK中提供了其它的一些方便的机制来完成这个目的，比如wait-and-notify（Object.wait和Object.notify）或者信号量等。
