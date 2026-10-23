// sproto-js ESM 入口文件
import sproto from './sproto.js';

// ESM 默认导出
export default sproto;

// ESM 命名导出
export { sproto };
export const createNew = sproto.createNew;