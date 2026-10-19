import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const COUNT_SH = '.claude/count.sh'
const CTX_OFF = '.claude/count/ctx.off'

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
    const { Box, Button } = $.ui.resolve(e)

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
        {hidden ? null : (
          <Button dimColor key="ctx" hotkey="c" label={`c ctx: ${isOff ? 'off' : 'on'}`} onPress={toggle} />
        )}
        {hidden ? null : (
          <Button dimColor key="finish" hotkey="f" label="f count:finish" onPress={say('count:finish')} />
        )}
        {hidden ? null : (
          <Button dimColor key="off" hotkey="o" label="o count:off" onPress={say('count:off')} />
        )}
        <Button dimColor key="fold" hotkey="h" label={hidden ? 'h ▸' : 'h ◂'} onPress={fold} />
      </Box>
    )
  })
}
