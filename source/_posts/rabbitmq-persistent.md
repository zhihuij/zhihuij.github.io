---
layout: post
title: "RabbitMQ持久化机制"
date: 2013-11-15 14:29
comments: true
toc: true
categories: 
    - Middleware
    - MQ
tags:
    - rabbitmq
    - storage
---

之前其实已经写过一篇关于RabbitMQ持久化的[文章](http://jzhihui.iteye.com/blog/1642324)，但那篇文章侧重代码层面的写入流程，对于持久化操作何时发生以及什么时候会刷新到磁盘等问题其实都没有搞清楚，这篇文章着重于关注这些问题。

<!--more-->

### 消息什么时候需要持久化？

根据[官方博文](http://www.rabbitmq.com/blog/2011/01/20/rabbitmq-backing-stores-databases-and-disks/)的介绍，RabbitMQ在两种情况下会将消息写入磁盘：

> 1. 消息本身在publish的时候就要求消息写入磁盘；
> 2. 内存紧张，需要将部分内存中的消息转移到磁盘；

### 消息什么时候会刷到磁盘？

> 1. 写入文件前会有一个Buffer，大小为1M（1048576），数据在写入文件时，首先会写入到这个Buffer，如果Buffer已满，则会将Buffer写入到文件（未必刷到磁盘）；
> 2. 有个固定的刷盘时间：25ms，也就是不管Buffer满不满，每隔25ms，Buffer里的数据及未刷新到磁盘的文件内容必定会刷到磁盘；
> 3. 每次消息写入后，如果没有后续写入请求，则会直接将已写入的消息刷到磁盘：使用Erlang的receive x after 0来实现，只要进程的信箱里没有消息，则产生一个timeout消息，而timeout会触发刷盘操作。

### 消息在磁盘文件中的格式

消息保存于$MNESIA/msg_store_persistent/x.rdq文件中，其中x为数字编号，从1开始，每个文件最大为16M（16777216），超过这个大小会生成新的文件，文件编号加1。消息以以下格式存在于文件中：

> <<Size:64, MsgId:16/binary, MsgBody>>

MsgId为RabbitMQ通过rabbit_guid:gen()每一个消息生成的GUID，MsgBody会包含消息对应的exchange，routing_keys，消息的内容，消息对应的协议版本，消息内容格式（二进制还是其它）等等。

#### 文件何时删除？

当所有文件中的垃圾消息（已经被删除的消息）比例大于阈值（GARBAGE_FRACTION = 0.5）时，会触发文件合并操作（至少有三个文件存在的情况下），以提高磁盘利用率。

publish消息时写入内容，ack消息时删除内容（更新该文件的有用数据大小），当一个文件的有用数据等于0时，删除该文件。

### 消息索引什么时候需要持久化？

索引的持久化与消息的持久化类似，也是在两种情况下需要写入到磁盘中：要么本身需要持久化，要么因为内存紧张，需要释放部分内存。

### 消息索引什么时候会刷到磁盘？

> 1. 有个固定的刷盘时间：25ms，索引文件内容必定会刷到磁盘；
> 2. 每次消息（及索引）写入后，如果没有后续写入请求，则会直接将已写入的索引刷到磁盘，实现上与消息的timeout刷盘一致。

### 消息索引在磁盘文件中的格式

每个队列会对队列中的消息维护一个索引，每入队列一个消息，索引加1，索引在持久化时，以2^14个（16384）entry为单位组成一个文件（Segment）。索引在写入时，未必会按序写入，为了避免过多的磁盘寻址，索引信息会首先保存在Journal文件中，当该文件中的entry数量达到65536个时，会将其中的内容写入到Segment文件中。其中Journal保存于$MNESIA/queues/md5(queueName)/journal.jif文件中，索引保存于$MNESIA/queues/md5(queueName)/x.idx文件中，其中的x为数字编号，类似于消息文件的编号。

索引信息在Segment文件中的格式有两种：

> 1. 对应publish消息：<<1:1, IsPersistent:1, RelSeq:14, MsgId:16/binary, Expiry:8/binary>>；
> 2. 对应deliver或者ack消息：<<01:2, RelSeq:14>>。

#### 文件何时删除？

rabbit_msg_index模块为每一个Segment维护一个unacked计数，每publish一个消息加1，每ack一个消息减1，当unacked=0时，文件删除。

**注：持久化文件的大小可通过配置参数msg_store_file_size_limit修改，journal文件中最大entry数量可通过参数queue_index_max_ journal_entries配置，具体参见[这里](http://www.rabbitmq.com/configure.html#config-items)**