from pathlib import Path
import subprocess
import shutil
import time
import os


def copy_files(files, source, target):
    for file_path in files:
        relative_path = file_path.relative_to(source)
        dest_path = target / relative_path
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(file_path, dest_path)
        print(f"   🟢 Copied: {file_path} -> {dest_path}")


def is_luac_file(file_path):
    try:
        with open(file_path, "rb") as f:
            header = f.read(4)
            return header == b"\x1bLua"
    except Exception:
        return False


def luac_files(files, source, target, luac_bin):
    for file_path in files:
        try:
            relative_path = file_path.relative_to(source)
            dest_path = target / relative_path
            dest_path.parent.mkdir(parents=True, exist_ok=True)

            if is_luac_file(file_path):
                shutil.copy(file_path, dest_path)
                print(f"   🟢 copy: {file_path} -> {dest_path}")
            else:
                cmd = f'{luac_bin} -o "{dest_path}" "{file_path}"'
                result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

                if result.returncode == 0:
                    print(f"   🟢 luac: {file_path} -> {dest_path}")
                else:
                    print(f"   ❌ Error processing {file_path}: {result.stderr}")

        except Exception as e:
            print(f"   ❌ Error processing {file_path}: {str(e)}")


def copy_dirs(dir_names, source_root, dist_root, exclude_paths=None):
    dist_root = Path(dist_root)
    dist_root.mkdir(parents=True, exist_ok=True)

    excluded_full_paths = []
    if exclude_paths:
        for p in exclude_paths:
            try:
                excluded_full_paths.append((source_root / p).resolve())
            except Exception:
                pass

    def ignore_function(directory, files):
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
        source_path = (source_root / dir_name).resolve()
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


def filter_paths(source, pattern, excluded_root_dirs):
    return [
        path
        for path in source.rglob(pattern)
        if not excluded_root_dirs.intersection(path.relative_to(source).parts)
    ]


if __name__ == "__main__":
    start_time = time.time()

    # example/ 是游戏根目录，../ 是引擎根目录
    game_root = Path(".").resolve()
    engine_root = game_root.parent
    target = game_root / "dist"

    if target.exists():
        shutil.rmtree(target)
        print("🗑️  已清空 dist 目录")

    luac_bin = str(engine_root / "bin" / "luac")

    # --- 引擎层 ---
    print("📂 收集引擎 so 文件 ...")
    engine_excluded = {"3rd", "example", "skynet"}
    engine_so = filter_paths(engine_root, "*.so", engine_excluded)
    # 只收集引擎自身的 lua（排除 example 和 3rd）
    engine_lua = filter_paths(engine_root, "*.lua", engine_excluded)
    copy_files(engine_so, engine_root, target)

    print("⚙️  编译/复制引擎 lua 文件 ...")
    luac_files(engine_lua, engine_root, target, luac_bin)

    # skynet 编译产物
    print("📂 收集 skynet 编译产物 ...")
    skynet_so = list((engine_root / "skynet" / "luaclib").rglob("*.so"))
    skynet_so += list((engine_root / "skynet" / "cservice").rglob("*.so"))
    for f in skynet_so:
        rel = f.relative_to(engine_root)
        dest = target / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(f, dest)
        print(f"   🟢 Copied: {f} -> {dest}")

    # --- 游戏层 ---
    print("📂 收集游戏 so 文件 ...")
    game_excluded = {"3rd", "dist"}
    game_so = filter_paths(game_root, "*.so", game_excluded)
    game_lua = filter_paths(game_root, "*.lua", game_excluded)
    copy_files(game_so, engine_root, target)

    print("⚙️  编译/复制游戏 lua 文件 ...")
    luac_files(game_lua, engine_root, target, luac_bin)

    print("📂 创建 logs 目录 ...")
    logs_dir = (target / "logs").resolve()
    logs_dir.mkdir(parents=True, exist_ok=True)
    print(f"   🟢 成功创建: {logs_dir}")

    print("📂 复制项目目录 ...")
    # 游戏层目录
    copy_dirs(
        dir_names=["example/etc", "example/tools", "example/proto", "example/schema", "example/build"],
        source_root=engine_root,
        dist_root=target,
        exclude_paths=[
            "example/tools/mongodb/db",
            "example/tools/etcd/etcd1_data",
            "example/tools/etcd/etcd2_data",
            "example/tools/etcd/etcd3_data",
        ],
    )
    # bin 目录
    copy_dirs(
        dir_names=["bin"],
        source_root=engine_root,
        dist_root=target,
    )

    print("📄 复制文档文件 ...")
    copy_files(
        [p for p in [engine_root / "README.md", engine_root / "LICENSE"] if p.exists()],
        engine_root,
        target,
    )

    # 打包成 zip 文件
    zip_name = game_root / "skyext"
    print(f"📦 正在打包 dist -> {zip_name}.zip ...")
    shutil.make_archive(str(zip_name), "zip", root_dir=target)
    print(f"🟢 打包完成: {zip_name}.zip")

    shutil.rmtree(target)

    elapsed = time.time() - start_time
    print(f"⏱️  总耗时: {elapsed:.2f}s")
