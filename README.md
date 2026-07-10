1.准备一个需要打包的文件夹，该文件夹目录结构如下：
dirA
  -version.txt                 #里面第一行内容为run文件的名称,如XXX
  -command.sh                  #需要对dirA执行的命令
  -bin 
      -py / sh / exec          #任意可运行程序
  -data_dir                   
      -file / dir              #数据文件夹
      
2. bash runnableCompress.sh <需要打包的文件夹名字>     #生成 XXX.run文件
3. bash XXX.sh                                      #执行command.sh
