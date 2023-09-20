---
layout: post
title: "队列系统问题总结"
date: 2013-10-30 16:13
comments: true
toc: true
categories: 
    - Middleware
tags:
    - erlang
    - tcp
    - btrace
---

## 概述

对队列系统至今出现的各种问题进行总结。这个系统主要是分为这么几个部分：

> * RabbitMQ：消息broker；
> * Proxy：架在RabbitMQ前面，主要作用是负载均衡及高可用：消息可以路由到后端多个结点，任一结点的异常不会影响客户端；并且可以让RabbitMQ更方便的进行水平扩展；
> * 客户端SDK：为了避免让产品方了解AMQP协议的细节（Exchange、bindings等），对标准的RabbitMQ客户端进行封装，只提供两个简单的接口：sendMessage，consumeMessage，并提供配置选项来定制客户端的行为。

<!--more-->

## Proxy无法接入TCP连接（代码问题）

### 现象

客户端无法建立TCP连接，查看TCP状态发现：客户端TCP连接处于ESTABLISHED状态，但服务端TCP连接处于SYC_RECV状态。抓包发送服务端在三次握手的第二步向客户端发送了SYN+ACK后没有接受客户端的ACK数据，如下图：

<img src="{{ root_url }}/images/amqp_tcp_connect.png" />

客户端认为三步握手已经完成，但是服务端却一直在重传握手第二步的数据，导致客户端一直在重传握手正常完成后应该发送的第一个数据包（AMQP的协议头）。

### 原因

一开始不太清楚为什么TCP会处于这种状态，后经大牛提醒：服务端在未accept的情况下处于SYC_RECV状态，如下图所示：

<img src="{{ root_url }}/images/tcp_handshake.jpg" />

(注：图片引用自@淘叔度微博，accept应该是在要SYN_RECV状态之后发生，而不是之前)

知道这个原因的前提下，查看代码（网络部分代码使用的是RabbitMQ的代码），会发现类似下面的代码：

{% codeblock lang:erlang %}
gen_event:which_handlers(error_logger),
prim_inet:async_accept(LSock, -1),
...
{% endcodeblock %}

通过Erlang的Remote Shell进入Proxy进程查看，发现代码果然阻塞在gen_event:which_handlers/1这行。看注释这行的目的主要是为了清空日志进程的信箱，如果在特定环境（如内网）下可以不用。实现上可以简化为一个进程向另一个进程发送一条消息，然后等待响应，然后怀疑目标进程挂了，但是重试后发现目标进程正常。。。（上述进程都是指Erlang进程）

怀疑RabbitMQ是不是也会出现类似的问题，但是跑了一段时间的测试，发现RabbitMQ本身并没有出现这个问题。而Proxy与RabbitMQ在这块不一样的是使用了一个Erlang的日志框架[lager](https://github.com/basho/lager)，难道跟这个有关系？去除lager依赖，再跑测试，问题不再出现。

### 解决方案

当前的解决方案是去除上面这句代码：gen_event:which_handlers/1，同时向lager的官方社区提了[issue](https://github.com/basho/lager/issues/176)。

## 客户端SDK死锁（代码问题）

### 现象

在一次更新后，发现使用SDK的Tomcat进程在一段时间后会出现线程数激增，客户端无响应。把Thread状态dump出来以后，看到大量线程在等锁：

{% codeblock lang:java %}
java.lang.Thread.State: BLOCKED (on object monitor)
	at com.netease.mq.client.AbstractSimpleClient.getChannel(AbstractSimpleClient.java:311)
	- waiting to lock <0x000000078b656bd8> (a com.netease.mq.client.producer.SimpleMessageProducer)
	at com.netease.mq.client.producer.SimpleMessageProducer.sendMessage(SimpleMessageProducer.java:78)
{% endcodeblock %}

而持有锁的进程在等待Proxy的响应：

{% codeblock lang:java %}
java.lang.Thread.State: WAITING (on object monitor)
	at java.lang.Object.wait(Native Method)
	at java.lang.Object.wait(Object.java:485)
	at com.rabbitmq.utility.BlockingCell.get(BlockingCell.java:50)
	- locked <0x00000007866a31c8> (a com.rabbitmq.utility.BlockingValueOrException)
	at com.rabbitmq.utility.BlockingCell.uninterruptibleGet(BlockingCell.java:89)
	- locked <0x00000007866a31c8> (a com.rabbitmq.utility.BlockingValueOrException)
	at com.rabbitmq.utility.BlockingValueOrException.uninterruptibleGetValue(BlockingValueOrException.java:33)
	at com.rabbitmq.client.impl.AMQChannel$BlockingRpcContinuation.getReply(AMQChannel.java:343)
	at com.rabbitmq.client.impl.AMQChannel.privateRpc(AMQChannel.java:216)
	at com.rabbitmq.client.impl.AMQChannel.exnWrappingRpc(AMQChannel.java:118)
	at com.rabbitmq.client.impl.ChannelN.confirmSelect(ChannelN.java:1052)
	at com.rabbitmq.client.impl.ChannelN.confirmSelect(ChannelN.java:61)
	at com.netease.mq.client.AbstractSimpleClient.createChannel(AbstractSimpleClient.java:342)
	at com.netease.mq.client.AbstractSimpleClient.getChannel(AbstractSimpleClient.java:323)
	- locked <0x000000078b656bd8> (a com.netease.mq.client.producer.SimpleMessageProducer)
	at com.netease.mq.client.producer.SimpleMessageProducer.sendMessage(SimpleMessageProducer.java:78)
{% endcodeblock %}

看到这个堆栈的第一反应是Proxy出问题了，但是查看同一时间Proxy的日志显示，在路由消息（createChannel）到后端的时候发生了超时，并关闭了客户端连接。但是客户端竟然没有抛出异常，诡异。

### 原因

无意之间发现一个处于Waiting状态的线程，也在等待Proxy的响应：

{% codeblock lang:java %}
java.lang.Thread.State: WAITING (on object monitor)
	at java.lang.Object.wait(Native Method)
	at java.lang.Object.wait(Object.java:485)
	at com.rabbitmq.utility.BlockingCell.get(BlockingCell.java:50)
	- locked <0x000000078669fc98> (a com.rabbitmq.utility.BlockingValueOrException)
	at com.rabbitmq.utility.BlockingCell.get(BlockingCell.java:65)
	- locked <0x000000078669fc98> (a com.rabbitmq.utility.BlockingValueOrException)
	at com.rabbitmq.utility.BlockingCell.uninterruptibleGet(BlockingCell.java:111)
	- locked <0x000000078669fc98> (a com.rabbitmq.utility.BlockingValueOrException)
	at com.rabbitmq.utility.BlockingValueOrException.uninterruptibleGetValue(BlockingValueOrException.java:37)
	at com.rabbitmq.client.impl.AMQChannel$BlockingRpcContinuation.getReply(AMQChannel.java:349)
	at com.rabbitmq.client.impl.ChannelN.close(ChannelN.java:567)
	at com.rabbitmq.client.impl.ChannelN.close(ChannelN.java:499)
	at com.rabbitmq.client.impl.ChannelN.close(ChannelN.java:492)
	at com.netease.mq.client.AbstractSimpleClient$1.onRemoval(AbstractSimpleClient.java:255)
	at com.google.common.cache.LocalCache.processPendingNotifications(LocalCache.java:2016)
	at com.google.common.cache.LocalCache$Segment.runUnlockedCleanup(LocalCache.java:3521)
	at com.google.common.cache.LocalCache$Segment.postWriteCleanup(LocalCache.java:3497)
	at com.google.common.cache.LocalCache$Segment.remove(LocalCache.java:3168)
	at com.google.common.cache.LocalCache.remove(LocalCache.java:4236)
	at com.google.common.cache.LocalCache$LocalManualCache.invalidate(LocalCache.java:4815)
	at com.netease.mq.client.AbstractSimpleClient$2.shutdownCompleted(AbstractSimpleClient.java:352)
{% endcodeblock %}

看到这个线程的堆栈，可以确定Proxy关闭连接的事件客户端SDK已经捕捉到，并且触发了相关处理逻辑（AbstractSimpleClient$2.shutdownCompleted）。后面的逻辑就是导致死锁的更新的主要内容：根据需要回收已经过期的channel。这时候，客户端SDK会向Proxy发送一个channel.close命令，然后等待响应，但是连接已经关闭了，所以永远不可能等到响应。问题是：

> * 这时候，需要回收的channel不知道连接已关闭？
> * 就算不知道，在已关闭的连接上发送数据不会抛出异常？

为了重现这个现象，修改Proxy的代码，channel数量到一定水平，新打开channel时产生与上述问题一致的行为：等待会使channel过期的时间后关闭连接，可以稳定重现死锁。然后回答下上面的两个问题：

> * 触发AbstractSimpleClient$2.shutdownCompleted逻辑的channel确实知道连接已经关闭，并且是第一个知道连接已经关闭的channel，其它的channel会依次得到通知；但是在第一个channel触发回收时，其它channel是不知道连接已经关闭；
> * 经过测试，服务端已经关闭的情况下，客户端在此连接上发送数据不会触发异常，参考[这里](http://ahuaxuan.iteye.com/blog/657511)及[这里](http://my.oschina.net/costaxu/blog/127394)。

### 解决方案

在回收Channel时，如果连接已经关闭，则不再发送关闭请求，直接跳过。

## 其它问题

### AMQP qos（设计问题）

因为Proxy的存在，后端多个结点在客户端看来像一个结点，但是basic.qos这条命令会发送到所有后端几点，这样导致客户端本来期望收到1条消息，但是实际会收到多条消息。这个导致在使用nodejs的AMQP客户端的会出现问题（nodejs客户端提供了一个不带参数的ack方法，只会ack最后一次收到的消息，可应用依赖于只收到一条消息，当收到多条消息时，就会将一条消息ack多次）。

但是这个问题要处理得当也比较麻烦，需要考虑各种情况下的调整：
> * 如果qos要求是1，但后端结点数量大于1，怎么处理？如果只发送到qos到一个结点，这个结点挂了，需要如何处理？
> * 如果qos比较大，可以平分到后端结点，那一个结点挂了，如何处理？调高其它结点的qos？那这个结点又恢复了，怎么处理？再把其它结点的qos调低？
> * 如果遇到扩容，缩容的需求怎么处理？

从上面的分析可知，这个问题要处理得当，Proxy会有很复杂的逻辑，所以当前的处理是保持现状，应用的业务逻辑不应依赖于qos的变化。

### connection reset（代码问题）

客户端SDK在运行一段时间后，会出现connection reset，查看日志后发现Proxy保存的channel数据有异常：channel在关闭时没有清除Proxy内与该channel相关的数据，而客户端又一直在打开，关闭channel，但是channel最多只能开到65535个，超过这个数量后会重新从1开始，导致使用了脏数据。

### RabbitMQ后端重启，Proxy重连后，无法下发数据（代码问题）

本来Proxy的设计是在后端结点重启时，Proxy会重试连接。实际在更新时，却发现Proxy重连成功后，数据无法下发到客户端，但是抓包发送数据发送到Proxy。测试后发现是Proxy在做重连逻辑时，未清除某些状态，导致数据一直缓存在Proxy这一层。

### basic.consume没有发送到HA模式下的所有结点（代码问题）

通过RabbitMQ的管理页面看到，建立到后端的连接，只有一个会消费消息，其它连接都没在干事。一开始怀疑客户端未发送正确发送basic.consume命令，后测试发现是Proxy在HA模式下的时候，只会将某些命令（queue.declare，exchange.declare等）发送到一个结点，但basic.consume需要发送到所有结点。

**[2013.11.14更新]**

### Proxy直接Crash（代码问题）

前一天晚上收到报警，两台机器的Proxy都挂了，上去服务器看了下，有erl_crash.dump文件，时间差不多，一个在00:10分，一个在00:12分，把dump文件拉到本地，用CrashDumpViewer查看，看到错误信息：

> * no more index entries in atom_tab (max=1048576)

看样子像是创建了大量的atom，在CrashDumpViewer里看到大量ClientReader进程注册名的atom，但是没看到其它相应工作进程的注册名。~~后来反应到Proxy前面有HAProxy~~，是要做定期健康检查的，每次的检查都需要新建一个TCP连接，同时创建一个ClientReader进程，但是这个TCP连接会马上断开，也就是不会发送我们的期望的AMQP协议数据。看了下代码，进程注册名称的行为果然发生在进程一创建的瞬间，而不是检测到AMQP协议数据的时候，所以每次的健康检查都会导致多一个atom，前端两台HAProxy就是每次检查多出2个atom，长期运行，最终导致atom超过最大数量。

**[2013.12.5更新]**

11.14的更新有问题，当时以为前端是HAProxy，其实不是。上次出现问题后，我以为另外一个部署环境也会出现同样的问题，但是却一直没有看到，当时以为两个环境的HAProxy配置有差异，后来跟SA确认后，才知道：1）出问题的环境前端部署的是LVS，因为这个环境用的是物理机；2）没出问题的环境用的才是HAProxy，因为后端是虚拟机，暂时没法用LVS。

也就是说LVS跟HAProxy的健康检查的机制不一样？试着在两个部署环境的测试环境中加日志，只要有TCP连接就打一条日志，结果是：1）LVS的环境每隔8秒会出一条日志，也就是说后端会收到LVS的健康检查连接；2）HAProxy的环境一条日志也没，难道根本就没收到健康检查的连接？诡异。。。

用tcpdump抓包后，才知道原来HAProxy在做健康检查的时候，三次握手根本都没完成，在第三步本应该发送ACK的时候，HAProxy发送了一个RST包，所以应用层不可能检测到连接，如下图所示：

<img src="{{ root_url }}/images/haproxy_health_chk.png" />

而LVS的健康检查是在三次握手完成后再发一个RST包来断开连接的，如下图所示：

<img src="{{ root_url }}/images/lvs_health_chk.png" />

那这样有什么好处，我觉得有两点：
> 1. 少发一个数据包，连接少倒没什么，如果有大量连接，可能HAProxy会更高效点；
> 2. 不完成三次连接，应用层就不会检测到连接，对应用的逻辑没有影响，有些应用可能在连接一建立就会做一些初始化工作或者打一些日志：我们的Proxy本来就是在连接一建立的就会打一条日志，后来就是因为在LVS环境下，大量的健康检查连接导致大量的日志，所以把日志打印推迟到收到实际的AMQP数据才打印。

从上面来看，HAProxy考虑的更周到。

**[2013.12.12更新]**

### 生产者Confirm超时（代码问题）

观察到的现象时，生产者偶尔会出现等待服务端confirm超时的现象（一开始设置的超时时间5秒，后来设置到10秒，30秒），发现问题依旧。一开始并没有很重视这个问题，主要有两个原因：1）超时不会导致消息丢失，只会导致消息重复，在我们的应用场景中，重复没有影响（客户端最终会做去重处理）；2）一开始的测试表明，通过Proxy及直接通过RabbitMQ都会导致超时，所以怀疑跟RabbitMQ的分布式机制有关系。

最近这个问题基本上每天都会出现，而且了解RabbitMQ的分布式机制后，觉得这个不是超时产生的原因，所以决定重做测试。一开始测试客户端在本地，很Happy的是跑第一遍的时候出现超时，虽然说超时的时机不确定，抓包后发现有丢包，也就是发送的数据包根本没到服务端，所以服务端也不可能会confirm，跟同事分析结果的时候，有人提醒我们本地连服务器的VPN是走UDP的，所以丢包也正常。。。，也就是说以前的测试结论也不成立：有可能只是通过Proxy会出问题，而直接通过RabbitMQ不会出问题。

基于以上了解，开始把测试程序部署到线上的机器上，跑了两天后，发现测试程序没出现超时的现象（不管是通过Proxy还是直接通过RabbitMQ），而线上程序还是基本每天有一两次的超时。看来只能通过线上的程序来诊断问题，随写了如下的Btrace脚本：

{% codeblock lang:java %}
@BTrace public class ConfirmTimeout {
    @TLS static Throwable currentException;

    @OnMethod(
        clazz="java.util.concurrent.TimeoutException",
        method="<init>"
    )
    public static void onThrow(@Self TimeoutException self) {
        println(self);
        currentException = self;
    }

    @OnMethod(
        clazz="com.rabbitmq.client.impl.ChannelN",
        method="waitForConfirms",
        location=@Location(Kind.THROW)
    ) 
    public static void onConfirm(@Self ChannelN ch) {
        if(currentException != null) {
            Field chNumField = field("com.rabbitmq.client.impl.AMQChannel", "_channelNumber");
            Field connField = field("com.rabbitmq.client.impl.AMQChannel", "_connection");
            Field nextSeqField = field("com.rabbitmq.client.impl.ChannelN", "nextPublishSeqNo");
            int chNum = getInt(chNumField, ch);
            long nextSeq = getLong(nextSeqField, ch);
            Object conn = get(connField, ch);
            long threadId = threadId(currentThread());
            String tmp = timestamp("yyyy-MM-dd HH:mm:ss.SSSZ");
            tmp = strcat(tmp, "  ");
            tmp = strcat(tmp, str(conn));
            tmp = strcat(tmp, " exception=> ");
            tmp = strcat(tmp, str(threadId));
            tmp = strcat(tmp, " : ");
            tmp = strcat(tmp, str(chNum));
            tmp = strcat(tmp, " -> ");
            tmp = strcat(tmp, str(nextSeq));
            println(tmp);
            currentException = null;
        }
    }

    @OnMethod(
        clazz="com.rabbitmq.client.impl.ChannelN",
        method="close"
    ) 
    public static void onCloseChannel(@Self ChannelN ch) {
            Field chNumField = field("com.rabbitmq.client.impl.AMQChannel", "_channelNumber");
            Field connField = field("com.rabbitmq.client.impl.AMQChannel", "_connection");
            Field nextSeqField = field("com.rabbitmq.client.impl.ChannelN", "nextPublishSeqNo");
            int chNum = getInt(chNumField, ch);
            long nextSeq = getLong(nextSeqField, ch);
            Object conn = get(connField, ch);
            long threadId = threadId(currentThread());
            String tmp = timestamp("yyyy-MM-dd HH:mm:ss.SSSZ");
            tmp = strcat(tmp, "  ");
            tmp = strcat(tmp, str(conn));
            tmp = strcat(tmp, " close=> ");
            tmp = strcat(tmp, str(threadId));
            tmp = strcat(tmp, " : ");
            tmp = strcat(tmp, str(chNum));
            tmp = strcat(tmp, " -> ");
            tmp = strcat(tmp, str(nextSeq));
            println(tmp);
    }

    @OnMethod(
        clazz="com.rabbitmq.client.impl.AMQConnection",
        method="createChannel",
        location=@Location(Kind.RETURN)
    ) 
    public static void onCreateChannel(@Self AMQConnection conn, @Return ChannelN ch) {
        Field chNumField = field("com.rabbitmq.client.impl.AMQChannel", "_channelNumber");
        int chNum = getInt(chNumField, ch);
        long threadId = threadId(currentThread());
        String tmp = timestamp("yyyy-MM-dd HH:mm:ss.SSSZ");
        tmp = strcat(tmp, "  ");
        tmp = strcat(tmp, str(conn));
        tmp = strcat(tmp, " create=> ");
        tmp = strcat(tmp, str(threadId));
        tmp = strcat(tmp, " : ");
        tmp = strcat(tmp, str(chNum));
        println(tmp);
    }
}
{% endcodeblock %}

主要需要搞清楚这么几个问题：1）发生超时问题的连接是哪一个？（本来需要打印出连接地址，发送Btrace不允许调用对象的toString，所以只能打印对象ID）；2）发生问题的线程是哪一个？3）发生问题的channel ID是哪一个？4）发送问题时客户端等待的confirm消息的seq是什么？

跑了一两天后，得到类似下面的输出日志：

{% codeblock lang:java %}
2013-12-11 16:57:11.733+0800  com.rabbitmq.client.impl.AMQConnection@4b0a1577 create=> 213 : 37
2013-12-11 17:58:29.578+0800  com.rabbitmq.client.impl.AMQConnection@4b0a1577 close=> 41 : 37 -> 3
2013-12-11 18:27:28.530+0800  com.rabbitmq.client.impl.AMQConnection@4b0a1577 create=> 196 : 37
2013-12-11 18:27:58.540+0800  com.rabbitmq.client.impl.AMQConnection@4b0a1577 exception=> 196 : 37 -> 2
{% endcodeblock %}

观察到的现象是只要出现类似上面的序列：1）create channel A；2）close channel A（close是客户端SDK的主动回收机制引起的）；3）create channel A；第三步创建的channel发送的第一次消息肯定超时。

当时虽然也想到可能是Proxy没有把老的channel数据清除掉，所以导致问题，但是因为这一块以前已经处理过，在channel关闭的时候Proxy会主动清除数据，所以觉得不可能是这里的问题。

所以只好根据这些日志，重现这个问题。我们的客户端SDK用google的guava库来做的回收，这个库的特点是：1）没有独立的线程来做回收；2）回收发生在数据读写时；3）回收是分段进行的，类似ConcurrentHashMap里的分段锁。这里有两个东西要注意：1）哪些channel的操作会触发目标channel的回收操作？2）每次读写都会触发回收操作么？ 其中第二个问题一开始想当然的以为每次读数据都会触发回收，后来发现写的测试程序无法重现错误序列，大概翻了下guava的代码，发现读操作只有积累到一定量的时候才会触发（目前阈值是64）。

测试程序搞定后，通过Proxy发送数据可以稳定重现问题，但是直接通过RabbitMQ发送数据没有问题，看来还是Proxy的问题。仔细查看代码后，发现类似这样的逻辑：

{% codeblock lang:java %}
process_frame(Frame, State#ch{channel = Channel}) ->
	NewState = handle_method(Method, State);
	put({channel, Channel});
	....

handle_method(#'channel.close', State#ch{channel = Channel}) -> 
	erase({channel, Channel}),
	State;
{% endcodeblock %}

了解Erlang的应该知道，erase是清除进程数据，put是添加（或更新）进程数据，也就是说channel.close的时候确实清了数据，但是外部调用函数又把它加回去了。。。