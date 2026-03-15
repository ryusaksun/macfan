import Foundation

/// SMC 键名常量定义
public enum SMCKeys {

    // MARK: - 风扇

    public static let fanCount = "FNum"
    public static let forceMode = "Ftst"

    public static func fanActualSpeed(_ id: Int) -> String { "F\(id)Ac" }
    public static func fanMinSpeed(_ id: Int) -> String { "F\(id)Mn" }
    public static func fanMaxSpeed(_ id: Int) -> String { "F\(id)Mx" }
    public static func fanTargetSpeed(_ id: Int) -> String { "F\(id)Tg" }

    /// M5 Pro 使用小写 F0md，旧款使用 F0Md
    public static func fanMode(_ id: Int) -> String { "F\(id)md" }
    public static func fanModeLegacy(_ id: Int) -> String { "F\(id)Md" }
    public static func fanStatus(_ id: Int) -> String { "F\(id)St" }

    // MARK: - 温度传感器

    public static let temperatureKeys: [(key: String, name: String)] = [
        ("TC0P", "CPU Proximity"),
        ("TC0D", "CPU Die"),
        ("TC0E", "CPU #1"),
        ("TC0F", "CPU #2"),
        ("TC1C", "CPU Core 1"),
        ("TC2C", "CPU Core 2"),
        ("TC3C", "CPU Core 3"),
        ("TC4C", "CPU Core 4"),
        ("TC5C", "CPU Core 5"),
        ("TC6C", "CPU Core 6"),
        ("TC7C", "CPU Core 7"),
        ("TC8C", "CPU Core 8"),
        ("TCXC", "CPU PECI"),
        ("Tp09", "CPU E-Core 1"),
        ("Tp0T", "CPU E-Core 2"),
        ("Tp01", "CPU P-Core 1"),
        ("Tp05", "CPU P-Core 2"),
        ("Tp0D", "CPU P-Core 3"),
        ("Tp0H", "CPU P-Core 4"),
        ("Tp0L", "CPU P-Core 5"),
        ("Tp0P", "CPU P-Core 6"),
        ("Tp0X", "CPU P-Core 7"),
        ("Tp0b", "CPU P-Core 8"),
        ("TG0P", "GPU Proximity"),
        ("TG0D", "GPU Die"),
        ("TG0T", "GPU Temperature"),
        ("Tg05", "GPU Core 1"),
        ("Tg0D", "GPU Core 2"),
        ("Tg0L", "GPU Core 3"),
        ("Tg0T", "GPU Core 4"),
        ("Tm02", "Memory 1"),
        ("Tm06", "Memory 2"),
        ("Tm0a", "Memory 3"),
        ("Tm0e", "Memory 4"),
        ("TM0P", "Memory Proximity"),
        ("TH0x", "NVMe"),
        ("TH0a", "SSD 1"),
        ("TH0b", "SSD 2"),
        ("TB0T", "Battery"),
        ("TB1T", "Battery 1"),
        ("TB2T", "Battery 2"),
        ("TW0P", "Airport"),
        ("Ts0P", "Palm Rest 1"),
        ("Ts0S", "Palm Rest 2"),
        ("Ts1P", "Palm Rest 3"),
        ("Ts1S", "Palm Rest 4"),
        ("TA0P", "Ambient"),
        ("TaLP", "Airflow Left"),
        ("TaRP", "Airflow Right"),
        ("TH0P", "HDD Proximity"),
    ]
}
