# skynet 游戏服务器 skyext

🎮 [WIP] 基于 Skynet 实现的一个游戏服务器 🚀 欢迎 Star & Fork！

目前还处于早期开发中，众多模块暂未开发完，只有部分代码可以看，仅用于学习参考！

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
./bin/skynet etc/game1.conf.lua
```

启动机器人客户端

```
./bin/skynet etc/robot.conf.lua
```

## 文档

- [skynet service 的 lua 消息处理接口封装](https://blog.hanxi.cc/p/97/)
- [skynet 的游戏工程目录结构](https://blog.hanxi.cc/p/99/)
- [Skynet 定时器模块的封装：从简单实现到高性能设计](https://blog.hanxi.cc/p/100/)
- [Skynet 中 MongoDB 数据库操作接口的封装设计](https://blog.hanxi.cc/p/101/)
- [skynet 相关文章](https://github.com/hanxi/blog/issues?q=is%3Aissue%20state%3Aopen%20label%3ASkynet)

## 讨论区

- QQ群: `677839887`
