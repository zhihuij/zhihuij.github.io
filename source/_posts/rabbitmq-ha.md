---
layout: post
title: "RabbitMQ HA机制"
date: 2013-11-12 11:05
comments: true
toc: true
categories: 
    - Middleware
    - MQ
tags:
    - rabbitmq
    - ha
---

RabbitMQ为了保证消息不丢失，提供了高可用机制，或者称为镜像队列，详细文档可以参考[这里](http://www.rabbitmq.com/ha.html)，本文试图搞清楚其实现细节。

<!--more-->

## 创建高可用队列

RabbitMQ在3.x之前是通过客户端在创建队列时传入特定参数还创建高可用队列的，3.x之后，所有高可用队列都是通过policy来管理，使用类似正则匹配的方式来决定哪些队列需要创建成镜像队列。

### 与普通队列的差别

普通队列只在创建结点上存在一个Erlang进程（amqqueue_process）来处理消息逻辑，而HA的队列存在两类进程：master进程（amqqueue_process）和slave进程（rabbit_mirror_queue_slave），每个进程包含一个实际用于处理消息逻辑的队列（rabbit_variable_queue）。整体结构如下图：

<img src="{{ root_url }}/images/rabbit_ha.png" />

## 消息流程

### 发送消息

生产消息的事件会通过rabbit_channel进程同时广播到master和slave进程（异步），并且在master进程收到消息后，会再通过GM将该消息广播到所有slave进程（异步），也就是说对于生产消息的事件，slave进程会同时收到两个消息：一个从GM发来，一个从rabbit_channel进程发来。消息流如下图所示：

<img src="{{ root_url }}/images/rabbit_ha_publish.png" />

代码里的文档对于为什么同时需要从channel发送消息到slave的解释如下：

> The key purpose of also sending messages directly from the channels
> to the slaves is that without this, in the event of the death of
> the master, messages could be lost until a suitable slave is
> promoted. However, that is not the only reason. A slave cannot send
> confirms for a message until it has seen it from the
> channel. Otherwise, it might send a confirm to a channel for a
> message that it might *never* receive from that channel. This can
> happen because new slaves join the gm ring (and thus receive
> messages from the master) before inserting themselves in the
> queue's mnesia record (which is what channels look at for routing).
> As it turns out, channels will simply ignore such bogus confirms,
> but relying on that would introduce a dangerously tight coupling.

也就是说不通过channel发送消息到slave进程可能会产生两个问题：
> 1. 如果master进程挂掉了，消息有可能会丢失：master收到消息，广播到slave进程之前挂掉，slave进程就不可能通过GM收到该消息；
> 2. 在slave进程已经加入到GM中，但是slave进程信息还没有写到mnesia数据库中时，slave进程可能只会收到从GM发送过来的消息，这时候，slave会发送一个从来没收到过的消息的confirm消息到channel进程；从上面的解释来看，RabbitMQ认为这样会带来强耦合的关系。

### confirm消息

master进程及slave进程在实际队列完成消息入队工作（可能会持久化到磁盘）后，将会发送进程（rabbit_channel）发送一个confirm消息，rabbit_channel进程只有在收到所有队列进程（master及slave）的confirm消息后，才会向客户端发回confirm消息。

### 消费消息

所有消费消息的相关事件（获取消息，ack消息，requeue消息）都是只发送到master进程，然后由master进程通过GM来广播这些事件到所有slave进程。消息流如下图所示：

<img src="{{ root_url }}/images/rabbit_ha_consume.png" />

## 节点变化

### 新结点加入

新的slave结点可以随时加入集群，但是加入之前的消息并不会同步到新的slave结点。也就是说在一开始，新的slave结点肯定会在一段时间内与master的内容不同步，随着旧消息被消费，新slave结点的内容会保持与master同步。

### Slave挂掉

基本无影响，连接在这个slave上的客户端需要重新连接到其它结点。

### Master挂掉

> 1. 一个slave会被选举为新的master，要求这个slave为所有slave中最老的结点；
> 2. Slave认为所有之前的Consumer都突然断开，然后会requeue所有之前未ACK的消息（ACK可能未到已挂掉的Master或者已经到已挂掉的Master，但在广播到到Slave之前，Master挂掉），这种情况下，会导致客户端收到重复的消息；
> 3. 未断开的Consumer会收到 Consumer Cancellation Notification，这时候Consumer应该重新订阅队列。

也就是说master结点的异常会产生两个问题：1）可能会丢消息；2）可能会收到重复消息。重复消息还可以接受（就算是普通队列也会面临这个问题，需要应用层来处理），但是丢消息对应用来说可能就会有点问题。

## 运维

### 网络分区

RabbitMQ提供了一个配置参数：cluster_partition_handling，可选值有三个：ignore，pause_minority，autoheal，具体什么意思可以参考[这里](http://www.rabbitmq.com/partitions.html)。

也可以自己手动来解决：在发生网络分区时，选一个分区，把另一个分区的RabbitMQ全部重启一遍就可以重新组成集群。按官方的意思，在这之后，最好把整个集群重启一次才能清除掉警告信息。