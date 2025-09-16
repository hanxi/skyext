# [skynet](https://github.com/cloudwu/skynet) 游戏服务器 skyext

🎮 [WIP] 基于 Skynet 实现的一个游戏服务器 🚀 欢迎 Star & Fork！

目前还处于早期开发中，仅用于学习参考！

## 运行测试

启动 etcd

```
cd tools/etcd
docker compose up -d
```

启动 mongodb

```
cd tools/mongodb
docker compose up -d
```

启动服务器

```
./bin/skynet etc/account1.conf.lua
./bin/skynet etc/account2.conf.lua
./bin/skynet etc/role1.conf.lua
./bin/skynet etc/role2.conf.lua
```

启动机器人客户端

```
./bin/skynet etc/robot.conf.lua
```

## 相关工程

- Demo 客户端工程: <https://github.com/hanxi/phaser-game>
- websocket 转 tcp 网关: <https://github.com/hanxi/goscon>
- 第三方登录鉴权: <https://github.com/hanxi/gamepass>

## 文档

- [skynet service 的 lua 消息处理接口封装](https://blog.hanxi.cc/p/97/)
- [skynet 的游戏工程目录结构](https://blog.hanxi.cc/p/99/)
- [Skynet 定时器模块的封装：从简单实现到高性能设计](https://blog.hanxi.cc/p/100/)
- [Skynet 中 MongoDB 数据库操作接口的封装设计](https://blog.hanxi.cc/p/101/)
- [skynet 相关文章](https://github.com/hanxi/blog/issues?q=is%3Aissue%20state%3Aopen%20label%3ASkynet)

## 功能

- [x] 通用定时器 timer
- [x] 日志服务 logger
- [x] 唯一 ID 生成
- [x] sproto 协议
- [x] MongoDB 数据库
- [x] MongoDB ORM
- [x] jwt 鉴权
- [x] 机器人 robot 客户端
- [x] etcd 分布式锁
- [x] etcd cluster 服务发现
- [x] http server 封装
- [x] account 节点
- [x] role 节点
- [ ] game 节点
- [ ] windows 版本

## 讨论区

- QQ群: `677839887`
