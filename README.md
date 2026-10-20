# image_migrate
# 容器/镜像迁移快照工具
# 功能：
#   1. 镜像导出  docker save -o 将镜像导出为 .tar 文件
#   2. 容器提交  docker commit 将容器打包为镜像，再 docker save 导出为 .tar 文件
#   3. 结果传输  scp 将 .tar 文件拷贝到另一台机器（自定义源IP、目的IP、目的保存地址）
