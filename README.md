# 游戏服务器 skyext

🎮 [WIP] [skyext](https://github.com/hanxi/skyext) 是一个基于 [skynet](https://github.com/cloudwu/skynet) 实现的一个游戏服务器

🚀 欢迎 Star & Fork！

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

- [Wiki](https://github.com/hanxi/skyext/wiki)
- [skynet service 的 lua 消息处理接口封装](https://blog.hanxi.cc/p/97/)
- [skynet 的游戏工程目录结构](https://blog.hanxi.cc/p/99/)
- [Skynet 定时器模块的封装：从简单实现到高性能设计](https://blog.hanxi.cc/p/100/)
- [Skynet 中 MongoDB 数据库操作接口的封装设计](https://blog.hanxi.cc/p/101/)
- [skynet 相关文章](https://github.com/hanxi/blog/issues?q=is%3Aissue%20state%3Aopen%20label%3ASkynet)

## 讨论区

- QQ群: `677839887`
