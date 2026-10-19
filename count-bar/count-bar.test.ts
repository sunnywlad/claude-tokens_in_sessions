import { describe, expect, mock, test } from 'claude-code/testing'

const HOME = '/home/alice'

const mountBar = async ($: any) =>
  $.ui.mount({ plugin: 'count-bar', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false } })

describe('count-bar', () => {
  test('reads the ctx.off flag under the caller\'s HOME', async ($, on) => {
    mock.env(on, { HOME })
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
})
