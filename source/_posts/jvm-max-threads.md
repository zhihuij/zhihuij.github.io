---
title: JVM 中可生成的最大 Thread 数量
date: 2011-08-09 20:53:00
comments: true
toc: true
categories: 
    - Java
tags:
    - java
    - concurrent
---

## 背景
最近想测试下Openfire下的最大并发数，需要开大量线程来模拟客户端。对于一个JVM实例到底能开多少个线程一直心存疑惑，所以打算实际测试下，简单google了把，找到影响线程数量的因素有下面几个：

<!--more-->

| []() |      |
| ---- | ---- |
| -Xms | intial java heap size |
| -Xmx | maximum java heap size |
| -Xss | the stack size for each thread |
| 系统限制 | 系统最大可开线程数 |

## 测试程序

{% codeblock lang:java %}
import java.util.concurrent.atomic.AtomicInteger;

public class TestThread extends Thread {
    private static final AtomicInteger count = new AtomicInteger();

    public static void main(String[] args) {
        while (true) {
            (new TestThread()).start();
        }
    }

    @Override
    public void run() {
        System.out.println(count.incrementAndGet());

        while (true)
        try {
                Thread.sleep(Integer.MAX_VALUE);
        } catch (InterruptedException e) {
                break;
        }
    }
}
{% endcodeblock %}

## 测试环境
系统：Ubuntu 10.04 Linux Kernel 2.6 （32位）
内存：2G
JDK：1.7

## 测试结果
### 不考虑系统限制

| -Xms | -Xmx | -Xss | 结果 |
| ---- | ---- | ---- | ---- |
| 1024m | 1024m | 1024k | 1737 |
| 1024m | 1024m | 64k | 26077 |
| 512m | 512m | 64k | 31842 |
| 256m | 256m | 64k | 31842 |

在创建的线程数量达到31842个时，系统中无法创建任何线程。

由上面的测试结果可以看出增大堆内存（-Xms，-Xmx）会减少可创建的线程数量，增大线程栈内存（-Xss，32位系统中此参数值最小为60K）也会减少可创建的线程数量。

### 结合系统限制
线程数量31842的限制是是由系统可以生成的最大线程数量决定的：/proc/sys/kernel/threads-max，可其默认值是32080。修改其值为10000：echo 10000 > /proc/sys/kernel/threads-max，修改后的测试结果如下：

| -Xms | -Xmx | -Xss | 结果 |
| ---- | ---- | ---- | ---- |
| 256m | 256m | 64k | 9761 |

这样的话，是不是意味着可以配置尽量多的线程？再做修改：echo 1000000 > /proc/sys/kernel/threads-max，修改后的测试结果如下：

| -Xms | -Xmx | -Xss | 结果 |
| ---- | ---- | ---- | ---- |
| 256m |256m | 64k | 32279 |
| 128m |128m | 64k | 32279 |

发现线程数量在达到32279以后，不再增长。查了一下，32位Linux系统可创建的最大pid数是32678，这个数值可以通过/proc/sys/kernel/pid_max来做修改（修改方法同threads-max），但是在32系统下这个值只能改小，无法更大。在threads-max一定的情况下，修改pid_max对应的测试结果如下：

| pid_max | -Xms | -Xmx | -Xss | 结果 |
| ---- | ---- | ---- | ---- | ---- |
| 1000 | 128m | 128m | 64k | 582 |
| 10000 | 128m | 128m | 64k | 9507 |

在Windows上的情况应该类似，不过相比Linux，Windows上可创建的线程数量可能更少。基于线程模型的服务器总要受限于这个线程数量的限制。

## 总结
JVM中可以生成的最大数量由JVM的堆内存大小、Thread的Stack内存大小、系统最大可创建的线程数量三个方面影响。具体数量可以根据Java进程可以访问的最大内存（32位系统上一般2G）、堆内存、Thread的Stack内存来估算。

## 续
在64位Linux系统（CentOS 6， 3G内存）下测试，发现还有一个参数是会限制线程数量：max user process（可通过ulimit –a查看，默认值1024，通过ulimit –u可以修改此值），这个值在上面的32位Ubuntu测试环境下并无限制。
将threads-max，pid_max，max user process，这三个参数值都修改成100000，-Xms，-Xmx尽量小（128m，64m），-Xss尽量小（64位下最小104k，可取值128k）。事先预测在这样的测试环境下，线程数量就只会受限于测试环境的内存大小（3G），可是实际的测试结果是线程数量在达到32K（32768，创建的数量最多的时候大概是33000左右）左右时JVM是抛出警告：Attempt to allocate stack guard pages failed，然后出现OutOfMemoryError无法创建本地线程。查看内存后发现还有很多空闲，所以应该不是内存容量的原因。Google此警告无果，暂时不知什么原因，有待进一步研究。

## 续2
今天无意中发现文章[7]，马上试了下，果然这个因素会影响线程创建数量，按文中描述把/proc/sys/vm/max_map_count的数量翻倍，从65536变为131072，创建的线程总数量达到65000+，电脑基本要卡死（3G内存）… 简单查了下这个参数的作用，在[8]中的描述如下：
> This file contains the maximum number of memory map areas a process may have. Memory map areas are used as a side-effect of calling malloc, directly by mmap and mprotect, and also when loading shared libraries.
>
> While most applications need less than a thousand maps, certain programs, particularly malloc debuggers, may consume lots of them, e.g., up to one or two maps per allocation.
>
> The default value is 65536.
	
OK，这个问题总算完满解决，最后总结下影响Java线程数量的因素：
> Java虚拟机本身：-Xms，-Xmx，-Xss；
> 系统限制：/proc/sys/kernel/pid_max，/proc/sys/kernel/thread-max，max_user_process（ulimit -u），/proc/sys/vm/max_map_count。

## 参考资料
1.	http://blog.krecan.net/2010/04/07/how-many-threads-a-jvm-can-handle/
2.	http://www.cyberciti.biz/tips/maximum-number-of-processes-linux-26-kernel-can-handle.html
3.	http://geekomatic.ch/2010/11/24/1290630420000.html
4.	http://stackoverflow.com/questions/763579/how-many-threads-can-a-java-vm-support
5.	http://www.iteye.com/topic/1035818
6.	http://hi.baidu.com/hexiong/blog/item/16dc9e518fb10c2542a75b3c.html
7.	https://listman.redhat.com/archives/phil-list/2003-August/msg00025.html
8.	http://www.linuxinsight.com/proc_sys_vm_max_map_count.html



