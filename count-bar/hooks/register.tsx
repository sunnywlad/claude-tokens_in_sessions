import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const COUNT_SH = '.claude/count.sh'
const CTX_OFF = '.claude/count/ctx.off'
const QUOTA = '.claude/quota.json'

// Bumped after a press so the band redraws; the flag itself is read from disk at each draw,
// because count.sh ctx off|on can also be run by hand.
const isHidden = atom({ plugin: 'count-bar', key: 'isHidden' } as const, true)
const redraws = atom({ plugin: 'count-bar', key: 'redraws' } as const, 0)

export const register: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    await read($, redraws)
    const hidden = await read($, isHidden)
    const home = (await $.env.get('HOME')) ?? ''
    const isOff = await $.fs.exists(`${home}/${CTX_OFF}`)
    const { Box, Button, Text } = $.ui.resolve(e)

    // Probe: the mod's own 5h reading beside the one the status line merged into quota.json.
    const fiveHour = (await $.session.usage()).rateLimits.find(r => r.kind === 'five_hour')
    const quota = await $.fs.read(`${home}/${QUOTA}`).then(
      text => JSON.parse(text as string),
      () => ({}),
    )
    const probe = `5h mod ${fiveHour?.percentUsed ?? '?'} · quota ${quota.used_percentage ?? '?'}`

    const toggle = async () => {
      await $.process.run(['bash', `${home}/${COUNT_SH}`, 'ctx', isOff ? 'on' : 'off'])
      await update($, redraws, n => n + 1)
    }
    const say = (text: string) => () => {
      void $.prompt.submit({ text, asUser: true })
    }

    const fold = () => update($, isHidden, h => !h)

    return (
      <Box width="100%" justifyContent="flex-end" gap={1}>
        {hidden ? <Text key="ctx-flag" dimColor={isOff}>c</Text> : <Text dimColor>{probe}</Text>}
        {hidden ? null : (
          <Button dimColor={isOff} key="ctx" hotkey="c" label={`c ctx: ${isOff ? 'off' : 'on'}`} onPress={toggle} />
        )}
        {hidden ? null : (
          <Button dimColor key="finish" hotkey="f" label="f count:finish" onPress={say('count:finish')} />
        )}
        {hidden ? null : (
          <Button dimColor key="off" hotkey="o" label="o count:off" onPress={say('count:off')} />
        )}
        <Button dimColor key="fold" hotkey="h" label={hidden ? '←' : '→'} onPress={fold} />
      </Box>
    )
  })
}
