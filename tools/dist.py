from pathlib import Path
import subprocess
import shutil
import time
import os


def copy_files(files, source, target):
    for file_path in files:
        # 计算相对于源目录的路径
        relative_path = file_path.relative_to(source)
        # 构建目标路径
        dest_path = target / relative_path

        # 创建目标文件的父目录（如果不存在）
        dest_path.parent.mkdir(parents=True, exist_ok=True)

        # 复制文件
        shutil.copy(file_path, dest_path)
        print(f"   🟢 Copied: {file_path} -> {dest_path}")


def is_luac_file(file_path):
    try:
        with open(file_path, "rb") as f:
            header = f.read(4)
            return header == b"\x1bLua"
    except Exception:
        return False


def luac_files(files, source, target):
    for file_path in files:
        try:
            # 计算相对于源目录的路径
            relative_path = file_path.relative_to(source)
            # 构建目标路径
            dest_path = target / relative_path

            # 创建目标文件的父目录（如果不存在）
            dest_path.parent.mkdir(parents=True, exist_ok=True)

            # 检查是否已经是编译后的文件
            if is_luac_file(file_path):
                shutil.copy(file_path, dest_path)
                print(f"   🟢 copy: {file_path} -> {dest_path}")
            else:
                cmd = f'./bin/luac -o "{dest_path}" "{file_path}"'
                result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

                if result.returncode == 0:
                    print(f"   🟢 luac: {file_path} -> {dest_path}")
                else:
                    print(f"   ❌ Error processing {file_path}: {result.stderr}")

        except Exception as e:
            print(f"   ❌ Error processing {file_path}: {str(e)}")


def copy_dirs(dir_names, dist_root="./dist", exclude_paths=None):
    """
    复制多个目录，并可选地忽略指定路径中的内容。
    """
    dist_root = Path(dist_root)
    dist_root.mkdir(parents=True, exist_ok=True)

    # 将排除路径标准化为 Path 并转为绝对路径
    excluded_full_paths = []
    if exclude_paths:
        for p in exclude_paths:
            try:
                excluded_full_paths.append((Path(".") / p).resolve())
            except Exception:
                pass

    def ignore_function(directory, files):
        """shutil.copytree 的 ignore 回调"""
        dir_path = Path(directory).resolve()
        ignored = []
        for f in files:
            file_path = (dir_path / f).resolve()
            if any(
                (
                    file_path.is_relative_to(excluded)
                    if hasattr(file_path, "is_relative_to")
                    else str(file_path).startswith(str(excluded) + "/")
                    or file_path == excluded
                )
                for excluded in excluded_full_paths
            ):
                ignored.append(f)
        return ignored

    for dir_name in dir_names:
        source_path = Path(f"./{dir_name}").resolve()
        target_path = dist_root / dir_name

        if not source_path.exists():
            print(f"   ⚠️  源目录不存在: {source_path}")
            continue

        if not source_path.is_dir():
            print(f"   ⚠️  不是目录: {source_path}")
            continue

        print(f"   📂 复制 {dir_name} 目录 ...")
        try:
            shutil.copytree(
                source_path, target_path, ignore=ignore_function, dirs_exist_ok=True
            )
            print(f"   🟢 成功复制: {source_path} -> {target_path}")
        except Exception as e:
            print(f"   ❌ 复制失败 {dir_name}: {e}")


def filter_paths(source, pattern, excluded_root_dirs, excluded_current_dirs):
    return [
        path
        for path in source.rglob(pattern)
        if not (
            excluded_root_dirs.intersection(path.parts)  # 完全排除的目录
            or (
                len(path.parts) > 1 and path.parts[0] in excluded_current_dirs
            )  # 当前目录下的
        )
    ]


if __name__ == "__main__":
    start_time = time.time()

    source = Path(".").resolve()  # 源根目录
    target = Path("./dist")  # 目标根目录
    if target.exists():
        shutil.rmtree(target)  # 清空目标目录
        print("🗑️  已清空 dist 目录")

    excluded_root_dirs = {"3rd"}  # 完全排除的目录
    excluded_current_dirs = {"etc", "skyext"}  # 只排除当前目录下的

    so_files = filter_paths(source, "*.so", excluded_root_dirs, excluded_current_dirs)
    lua_files = filter_paths(source, "*.lua", excluded_root_dirs, excluded_current_dirs)

    print("📂 复制 so 文件 ...")
    copy_files(so_files, source, target)

    print("⚙️  编译/复制 lua 文件 ...")
    luac_files(lua_files, source, target)

    print("📂 创建 logs 目录 ...")
    logs_dir = Path(target / "logs").resolve()
    logs_dir.mkdir(parents=True, exist_ok=True)
    print(f"   🟢 成功创建: {logs_dir}")

    print("📂 复制项目目录 ...")
    copy_dirs(
        dir_names=[
            "etc",
            "tools",
            "bin",
            "proto",
            "schema",
            "build",
        ],
        exclude_paths=[
            "./tools/mongodb/db",
            "./tools/etcd/etcd1_data",
            "./tools/etcd/etcd2_data",
            "./tools/etcd/etcd3_data",
        ],
    )

    print("📄 复制文档文件 ...")
    copy_files(
        [
            source / "README.md",
            source / "LICENSE",
        ],
        source,
        target,
    )

    # 打包成 zip 文件
    print("📦 正在打包 dist -> skyext.zip ...")
    shutil.make_archive("skyext", "zip", root_dir=target)
    print("🟢 打包完成: skyext.zip")

    shutil.rmtree(target)  # 清空目标目录

    elapsed = time.time() - start_time
    print(f"⏱️  总耗时: {elapsed:.2f}s")
