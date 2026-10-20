import { describe, expect, mock, test } from 'claude-code/testing'

const HOME = '/home/alice'

const mountBar = async ($: any) =>
  $.ui.mount({ plugin: 'count-bar', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false } })

// The probe reads quota.json and session.usage on every draw; tests that look elsewhere stub both.
const mockReadings = (on: any, quota: string | null = '{}') => {
  on('fs.read', async () => {
    if (quota === null) throw new Error('ENOENT')
    return { value: quota } as any
  })
  on('session.usage', async () => ({ value: { startedAt: 0, context: {}, rateLimits: [] } }) as any)
}

describe('count-bar', () => {
  test('reads the ctx.off flag under the caller\'s HOME', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    const asked: string[] = []
    on('fs.exists', async (_$, e) => {
      asked.push(e.path)
      return { value: false }
    })
    const bar = await mountBar($)
    await bar.drawn()
    expect(asked).toContain(`${HOME}/.claude/count/ctx.off`)
  })

  test('runs count.sh from the caller\'s HOME on the ctx button', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    const ran: (readonly string[])[] = []
    on('fs.exists', async () => ({ value: false }))
    on('process.run', async (_$, e) => {
      ran.push(e.argv)
      return { value: { exitCode: 0, stdout: '', stderr: '' } } as any
    })
    const bar = await mountBar($)
    await bar.press({ key: 'fold' })
    await bar.press({ key: 'ctx' })
    expect(ran).toEqual([['bash', `${HOME}/.claude/count.sh`, 'ctx', 'off']])
  })

  test('the finish and off buttons submit count:finish and count:off', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    on('fs.exists', async () => ({ value: false }))
    const sent: string[] = []
    on('prompt.submit', async (_$, e) => {
      sent.push(e.text)
      return { drop: 'test' } as any
    })
    const bar = await mountBar($)
    await bar.press({ key: 'fold' })
    await bar.press({ key: 'finish' })
    await bar.press({ key: 'off' })
    expect(sent).toEqual(['count:finish', 'count:off'])
  })

  test('shows the mod\'s 5h reading next to quota.json\'s when unfolded', async ($, on) => {
    mock.env(on, { HOME })
    on('fs.exists', async () => ({ value: false }))
    on('fs.read', async (_$, e) => {
      expect(e.path).toBe(`${HOME}/.claude/quota.json`)
      return { value: JSON.stringify({ used_percentage: 41 }) } as any
    })
    on('session.usage', async () => ({
      value: { startedAt: 0, context: {}, rateLimits: [{ kind: 'five_hour', percentUsed: 43.5 }] },
    }) as any)
    const bar = await mountBar($)
    await bar.press({ key: 'fold' })
    expect((await bar.find({ type: 'Text', text: /5h/ }))?.text).toBe('5h mod 43.5 · quota 41')
  })

  test('a missing quota.json shows ? instead of breaking the bar', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on, null)
    on('fs.exists', async () => ({ value: false }))
    const bar = await mountBar($)
    await bar.press({ key: 'fold' })
    expect((await bar.find({ type: 'Text', text: /5h/ }))?.text).toBe('5h mod ? · quota ?')
  })

  test('folded, only the c flag shows, white when ctx is on and grey when off', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    let isOff = false
    on('fs.exists', async () => ({ value: isOff }))
    const bar = await mountBar($)
    const flag = await bar.find({ type: 'Text', text: 'c' })
    expect(flag?.props?.dimColor ?? false).toBe(false)
    expect(await bar.find({ key: 'finish' })).toBeUndefined()
    isOff = true
    await bar.press({ key: 'fold' })
    await bar.press({ key: 'fold' })
    expect((await bar.find({ type: 'Text', text: 'c' }))?.props?.dimColor).toBe(true)
  })

  test('the fold button is a bare arrow, pointing the way it will go', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    on('fs.exists', async () => ({ value: false }))
    const bar = await mountBar($)
    expect((await bar.find({ key: 'fold' }))?.text).toBe('←')
    await bar.press({ key: 'fold' })
    expect((await bar.find({ key: 'fold' }))?.text).toBe('→')
  })

  test('unfolded, the ctx button is white when on and grey when off', async ($, on) => {
    mock.env(on, { HOME })
    mockReadings(on)
    on('fs.exists', async () => ({ value: false }))
    const bar = await mountBar($)
    await bar.press({ key: 'fold' })
    expect((await bar.find({ key: 'ctx' }))?.props?.dimColor ?? false).toBe(false)
    expect((await bar.find({ key: 'finish' }))?.props?.dimColor).toBe(true)
  })
})
