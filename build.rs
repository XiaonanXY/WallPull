fn main() {
    println!("cargo:rerun-if-changed=Assets/AppIcon.ico");
    println!("cargo:rerun-if-changed=Assets/TrayIcon.ico");
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=frontend/dist");

    let mut res = winresource::WindowsResource::new();
    res.set_icon_with_id("Assets/AppIcon.ico", "1");
    res.set_icon_with_id("Assets/TrayIcon.ico", "2");
    res.set_manifest_file("app.manifest");
    res.set("ProductName", "WallPull");
    res.set("CompanyName", "Xiaonan");
    res.set("FileDescription", "WallPull - 开源免费的 Wallpaper Engine 创意工坊壁纸管理工具");
    res.set("FileVersion", "1.0.1.0");
    res.set("ProductVersion", "1.0.1.0");
    res.set("LegalCopyright", "Copyright (C) 2026 Xiaonan (GNU GPL-3.0)");
    res.set("Comments", "https://github.com/XiaonanXY/WallPull");
    if let Err(err) = res.compile() {
        panic!("Failed to compile Windows resources: {err}");
    }
}
