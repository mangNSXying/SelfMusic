/**
 * IDE-only 环境类型垫片（供 VS Code TypeScript 语言服务使用）。
 *
 * 为什么不用 npm 安装 @types/node：flutter 工具在每次 buildHap/buildApp 时
 * 会删除并重写 frontend/ohos/package.json，再执行 npm install（npm 7+ 会清除
 * 未在 package.json 声明的包），安装物无法在下次构建后存活。
 *
 * 注意：本文件必须保持“脚本上下文”——不得出现顶层 import/export，
 * 否则所有 declare 声明将失去全局作用。
 * 真实构建由 Hvigor 自带 TypeScript 工具链完成，不读取本文件。
 *
 * 环境声明（declare module）只在模块“解析失败”时作为回退生效：
 * - 'path'、'@ohos/hvigor-ohos-plugin' 无处可解析 → 本文件的环境声明生效；
 * - 'flutter-hvigor-plugin' 在 node_modules 有可解析包（junction 指向
 *   Flutter SDK 源码）→ 环境声明不生效，由 tsconfig.json 的 paths 强制
 *   映射到 hvigor-types/flutter-hvigor-plugin.d.ts。
 */

declare const __dirname: string;

declare module 'path' {
  export function dirname(p: string): string;
  export function join(...paths: string[]): string;
  export function resolve(...pathSegments: string[]): string;
  const path: {
    dirname: typeof dirname;
    join: typeof join;
    resolve: typeof resolve;
  };
  export default path;
}

declare module '@ohos/hvigor-ohos-plugin' {
  export const hapTasks: (module: object) => object;
  export const appTasks: (module: object) => object;
  export const harTasks: (module: object) => object;
}
