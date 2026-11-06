/// 正反/循环按钮的统一入口：返回 [current] 在 [cycle] 中的下一项。
///
/// - 二态按钮（全部展开/折叠、全选/全不选）：环传 `[true, false]`——
///   false（含半开/半选）时下一次点击落到环首（展开/全选）；
/// - 三态按钮（排序 升序 → 降序 → 默认）：环传 `[升, 降, 默认]`。
///
/// [current] 不在环内（如排序切到另一个字段）时取环首。
T nextInCycle<T>(T current, List<T> cycle) =>
    cycle[(cycle.indexOf(current) + 1) % cycle.length];
