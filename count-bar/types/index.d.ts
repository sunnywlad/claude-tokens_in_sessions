export type Redraws = number

declare module 'claude-code' {
  interface PluginState {
    'count-bar': { redraws: Redraws; isHidden: boolean }
  }
}
