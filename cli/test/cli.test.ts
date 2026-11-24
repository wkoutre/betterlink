// Runs the CLI as a user or agent would, against the real app binary
// (`make build` first) and a temporary settings folder.
import { describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dir, '..', '..')
const app = process.env.BETTERLINK_APP_BINARY ?? join(root, 'dist/betterlink.app/Contents/MacOS/Betterlink')
const bin = join(import.meta.dir, '..', 'src', 'bin.ts')

function home(): string {
  const d = mkdtempSync(join(tmpdir(), 'bl-cli-'))
  chmodSync(d, 0o700)
  return d
}

function run(dir: string, ...args: string[]) {
  const r = spawnSync('bun', [bin, ...args, '--json'], {
    encoding: 'utf8',
    env: { ...process.env, BETTERLINK_HOME: dir, BETTERLINK_APP_BINARY: app },
  })
  let json: any
  try { json = JSON.parse(r.stdout) } catch { json = undefined }
  return { code: r.status, json, stdout: r.stdout, stderr: r.stderr }
}

/** A Chromium browser installed on this Mac. A fallback in a browser the Mac
 *  lacks is replaced by the default, and CI has Chrome, not Brave. */
function chromium(dir: string): string {
  const browser = run(dir, 'browsers', 'list').json.find((b: any) => b.family === 'chromium')?.name
  if (!browser) throw new Error('This test needs one Chromium browser installed.')
  return browser
}

describe.skipIf(!existsSync(app))('betterlink CLI', () => {
  test('lists every command for agents, and has no update command', () => {
    const r = spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } })
    for (const c of ['rules add', 'rules move', 'keys add', 'keys remove', 'fallback set', 'profiles import', 'config check', 'folder set', 'login set', 'menu-bar set', 'toast set', 'updates set', 'folder reset', 'default-browser set', 'test']) {
      expect(r.stdout).toContain(`betterlink ${c}`)
    }
    const help = spawnSync('bun', [bin, '--help'], { encoding: 'utf8' }).stdout
    expect(help).not.toContain('--update')
  })

  test('builds a sidebar: Sidebar Profiles, folders, links, Favorites, moves', () => {
    const d = home()
    expect(run(d, 'sidebar', 'profiles', 'add', '--name', 'Work').code).toBe(0)
    const folder = run(d, 'sidebar', 'add-folder', '--profile', 'Work', '--name', 'Docs').json.id as string
    const link = run(d, 'sidebar', 'add-link', '--profile', 'Work', '--url', 'https://example.com/a', '--title', 'A', '--to', folder.slice(0, 8)).json.id as string
    expect(run(d, 'sidebar', 'add-link', '--profile', 'Work', '--url', 'https://mail.example.com', '--to', 'favorites').code).toBe(0)
    expect(run(d, 'sidebar', 'move', link, '--profile', 'Work', '--to', 'favorites', '--position', '1').code).toBe(0)
    expect(run(d, 'sidebar', 'remove', folder, '--profile', 'Work').code).toBe(0) // empty now
    const work = run(d, 'sidebar', 'list').json.find((p: any) => p.name === 'Work')
    expect(work.favorites.map((f: any) => f.url)).toEqual(['https://example.com/a', 'https://mail.example.com'])
    expect(work.items).toEqual([])
    // Several Sidebar Profiles: which one must be said.
    expect(run(d, 'sidebar', 'add-link', '--url', 'https://x.example').code).not.toBe(0)
    for (const c of ['sidebar profiles assign', 'sidebar import', 'sidebar settings set', 'tabs list', 'tabs close-others']) {
      expect(spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } }).stdout).toContain(`betterlink ${c}`)
    }
  })

  test('adds, lists, tests, moves and removes rules', () => {
    const d = home()
    const browser = chromium(d)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Profile 1', '--name', 'Work').code).toBe(0)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Default', '--name', 'Personal').code).toBe(0)
    expect(run(d, 'rules', 'add', '--kind', 'domain', '--pattern', 'example.com', '--profile', 'Work').code).toBe(0)
    expect(run(d, 'rules', 'add', '--kind', 'startsWith', '--pattern', 'https://github.com/acme', '--profile', 'Work').code).toBe(0)
    expect(run(d, 'fallback', 'set', '--browser', browser, '--profile', 'Personal').code).toBe(0)

    let list = run(d, 'rules', 'list').json
    expect(list.map((r: any) => r.pattern)).toEqual(['example.com', 'https://github.com/acme'])

    expect(run(d, 'rules', 'move', list[1].id, '--to', '1').code).toBe(0)
    list = run(d, 'rules', 'list').json
    expect(list[0].pattern).toBe('https://github.com/acme')

    const hit = run(d, 'test', 'https://app.example.com/x').json
    expect(hit.profileName).toBe('Work')
    const miss = run(d, 'test', 'https://evil.com\\@example.com/').json
    expect(miss.profileName).toBe('Personal')

    expect(run(d, 'rules', 'remove', list[0].id).code).toBe(0)
    expect(run(d, 'rules', 'list').json.length).toBe(1)
  })

  test('modifier keys pick a profile for the held keys only', () => {
    const d = home()
    const browser = chromium(d)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Profile 1', '--name', 'Work').code).toBe(0)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Default', '--name', 'Personal').code).toBe(0)
    expect(run(d, 'fallback', 'set', '--browser', browser, '--profile', 'Personal').code).toBe(0)
    expect(run(d, 'keys', 'add', '--keys', 'ctrl,cmd', '--profile', 'Work').code).toBe(0)

    const list = run(d, 'keys', 'list').json
    expect(list.map((k: any) => k.keys)).toEqual([['control', 'command']])
    expect(list[0].symbols).toBe('⌃⌘')

    expect(run(d, 'test', 'https://example.com/', '--keys', 'control,command').json.profileName).toBe('Work')
    // Exactly these keys: one more, one fewer, or none opens as usual.
    expect(run(d, 'test', 'https://example.com/', '--keys', 'control,option,command').json.profileName).toBe('Personal')
    expect(run(d, 'test', 'https://example.com/', '--keys', 'command').json.profileName).toBe('Personal')
    expect(run(d, 'test', 'https://example.com/').json.profileName).toBe('Personal')

    // The same keys twice, an unknown key and no keys are refused.
    expect(run(d, 'keys', 'add', '--keys', 'command,control', '--profile', 'Personal').code).not.toBe(0)
    expect(run(d, 'keys', 'add', '--keys', 'hyper', '--profile', 'Personal').code).not.toBe(0)
    expect(run(d, 'keys', 'add', '--keys', '', '--profile', 'Personal').code).not.toBe(0)
    // A profile a key rule uses can't be removed.
    expect(run(d, 'profiles', 'remove', '--browser', browser, '--directory', 'Profile 1').code).not.toBe(0)

    expect(run(d, 'keys', 'update', list[0].id, '--keys', 'option,command').code).toBe(0)
    expect(run(d, 'test', 'https://example.com/', '--keys', 'option,command').json.profileName).toBe('Work')
    expect(run(d, 'keys', 'remove', list[0].id).code).toBe(0)
    expect(run(d, 'keys', 'list').json).toEqual([])
  })

  test('a refused change exits non-zero with the reason', () => {
    const d = home()
    // The profile must exist, so the rule is refused for its pattern alone.
    expect(run(d, 'profiles', 'add', '--browser', chromium(d), '--directory', 'Profile 1', '--name', 'Work').code).toBe(0)
    const r = run(d, 'rules', 'add', '--kind', 'domain', '--pattern', 'not a domain', '--profile', 'Work')
    expect(r.code).not.toBe(0)
    expect(JSON.stringify(r.json ?? r.stdout + r.stderr)).toContain('domain')
    expect(run(d, 'rules', 'list').json).toEqual([])
  })

  test('on/off switches send what was typed', () => {
    const d = home()
    expect(run(d, 'settings', 'set', '--show-log', 'on').code).toBe(0)
    expect(run(d, 'settings', 'get').json.showLog).toBe(true)
    expect(run(d, 'settings', 'set', '--show-log', 'off').code).toBe(0)
    expect(run(d, 'settings', 'get').json.showLog).toBe(false)
    expect(run(d, 'settings', 'set', '--show-log', 'false').code).not.toBe(0)
  })

  test('login set off sends enabled: false', () => {
    // A stand-in app that prints what it was asked, so the real login item is never touched.
    const d = home()
    const fake = join(d, 'fake-app')
    // Saves the JSON input ($3, after `agent <command>`) and answers ok.
    writeFileSync(fake, `#!/bin/sh\nprintf '%s' "$3" > '${join(d, 'sent.json')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    for (const [word, sent] of [['off', false], ['on', true]] as const) {
      const r = spawnSync('bun', [bin, 'login', 'set', '--enabled', word, '--json'], {
        encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
      })
      expect(r.status).toBe(0)
      expect(JSON.parse(readFileSync(join(d, 'sent.json'), 'utf8'))).toEqual({ enabled: sent })
    }
  })

  test('menu-bar set off sends shown: false', () => {
    // A stand-in app, so the real setting is never touched.
    const d = home()
    const fake = join(d, 'fake-app')
    writeFileSync(fake, `#!/bin/sh\nprintf '%s %s' "$2" "$3" > '${join(d, 'sent.txt')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    for (const [word, sent] of [['off', false], ['on', true]] as const) {
      const r = spawnSync('bun', [bin, 'menu-bar', 'set', '--shown', word, '--json'], {
        encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
      })
      expect(r.status).toBe(0)
      const [command, json] = readFileSync(join(d, 'sent.txt'), 'utf8').split(' ')
      expect(command).toBe('menu-bar.set')
      expect(JSON.parse(json)).toEqual({ shown: sent })
    }
  })

  test('toast set sends what was typed', () => {
    // A stand-in app, so the real setting is never touched.
    const d = home()
    const fake = join(d, 'fake-app')
    writeFileSync(fake, `#!/bin/sh\nprintf '%s %s' "$2" "$3" > '${join(d, 'sent.txt')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    const cases: [string[], unknown][] = [
      [['--shown', 'off'], { shown: false }],
      [['--position', 'bottom'], { position: 'bottom' }],
      [['--shown', 'on', '--position', 'top'], { shown: true, position: 'top' }],
    ]
    for (const [args, sent] of cases) {
      const r = spawnSync('bun', [bin, 'toast', 'set', ...args, '--json'], {
        encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
      })
      expect(r.status).toBe(0)
      const [command, json] = readFileSync(join(d, 'sent.txt'), 'utf8').split(' ')
      expect(command).toBe('toast.set')
      expect(JSON.parse(json)).toEqual(sent)
    }
  })

  test('updates set off sends automatic: false', () => {
    // A stand-in app, so the real setting is never touched.
    const d = home()
    const fake = join(d, 'fake-app')
    writeFileSync(fake, `#!/bin/sh\nprintf '%s %s' "$2" "$3" > '${join(d, 'sent.txt')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    const r = spawnSync('bun', [bin, 'updates', 'set', '--automatic', 'off', '--json'], {
      encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
    })
    expect(r.status).toBe(0)
    const [command, json] = readFileSync(join(d, 'sent.txt'), 'utf8').split(' ')
    expect(command).toBe('updates.set')
    expect(JSON.parse(json)).toEqual({ automatic: false })
  })

  test('folder reset asks for the standard folder', () => {
    const d = home()
    const fake = join(d, 'fake-app')
    // Saves the JSON input ($3, after `agent <command>`) and answers ok.
    writeFileSync(fake, `#!/bin/sh\nprintf '%s' "$3" > '${join(d, 'sent.json')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    const r = spawnSync('bun', [bin, 'folder', 'reset', '--json'], {
      encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
    })
    expect(r.status).toBe(0)
    expect(JSON.parse(readFileSync(join(d, 'sent.json'), 'utf8'))).toEqual({ standard: true })
  })

  test('an app that is not there gives APP_NOT_FOUND and its hint', async () => {
    const { core, appNotFoundHint } = await import('../src/bin')
    const saved = process.env.BETTERLINK_APP_BINARY
    delete process.env.BETTERLINK_APP_BINARY
    try {
      expect(() => core('status')).toThrow(expect.objectContaining({ code: 'APP_NOT_FOUND', hint: appNotFoundHint }))
      expect(appNotFoundHint).toContain('Install Command')
      expect(appNotFoundHint).toContain('mkdir -p ~/.local/bin')
      expect(appNotFoundHint).toContain('PATH')
    } finally {
      // Assigning undefined would store the string "undefined".
      if (saved === undefined) delete process.env.BETTERLINK_APP_BINARY
      else process.env.BETTERLINK_APP_BINARY = saved
    }
  })

  test('a missing app is a clear error, not a crash', () => {
    const r = spawnSync('bun', [bin, 'status', '--json'], {
      encoding: 'utf8',
      env: { ...process.env, BETTERLINK_HOME: home(), BETTERLINK_APP_BINARY: '/nonexistent/Betterlink' },
    })
    expect(r.status).not.toBe(0)
    expect(r.stdout + r.stderr).toContain("didn't answer")
  })
})
