# 📦 可执行压缩包 (Run) 打包与使用指南

## 1. 准备打包目录

首先，准备一个需要打包的文件夹（例如 `dirA`）。请确保该文件夹严格遵循以下目录结构配置：

```text
dirA/
├── version.txt       # 配置文件：第一行需填写生成的 run 文件名称（例如：XXX）
├── command.sh        # 执行脚本：需要自动执行的操作命令
├── bin/              # 可执行程序目录
│   └── [py/sh/exec]  # 存放任意可运行程序（如 Python 脚本、Shell 脚本或二进制程序）
└── data_dir/         # 数据存储目录
    └── [file/dir]    # 程序运行依赖的数据文件或子文件夹
```

## 2. 执行打包命令，生成 XXX.run文件
```shell
bash runnableCompress.sh <需要打包的文件夹名字>
```

## 3. 运行 XXX.run文件，会自动执行command.sh
```shell
bash XXX.run
```

