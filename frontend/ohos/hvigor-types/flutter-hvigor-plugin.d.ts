/**
 * flutter-hvigor-plugin 的 IDE 类型垫片（模块形式）。
 *
 * node_modules 内存在同名可解析包（junction 指向 Flutter SDK 源码），
 * 环境声明（declare module）此时不会生效，因此必须由 tsconfig.json 的
 * paths 将 'flutter-hvigor-plugin' 强制映射到本文件。
 * SDK 真实源码依赖 @ohos/hvigor 等 hvigor 内部模块（VS Code 下不可解析），
 * 不应被拖入 IDE 类型程序；本垫片签名与 SDK 源码保持一致。
 */

export interface HvigorPlugin {
  pluginId: string;
  apply(rootNode: object): void;
}

export function flutterHvigorPlugin(flutterProjectPath: string, flutterProjectType?: number): HvigorPlugin;

export function injectNativeModules(nativeProjectPath: string, flutterProjectPath: string, flutterProjectType?: number): void;
