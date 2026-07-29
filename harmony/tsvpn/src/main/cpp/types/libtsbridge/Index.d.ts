// Type declarations for the native NAPI module `libtsbridge.so`.
// Imported from ArkTS as: import tsbridge from 'libtsbridge.so'
export const start: (
  fd: number,
  stateDir: string,
  hostname: string,
  controlURL: string,
  authKey: string
) => string;
export const updateTun: (fd: number) => string;
export const version: () => string;
export const loginUrl: () => string;
export const status: () => string;
export const stop: () => void;
