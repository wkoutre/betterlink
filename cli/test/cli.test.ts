// Runs the CLI as a user or agent would, against the real app binary
// (`make build` first) and a temporary settings folder.
import { describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
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
    for (const c of ['sidebar profiles assign', 'sidebar import', 'sidebar settings set', 'tabs list', 'tabs extension', 'tabs close-others', 'tabs send', 'tabs find']) {
      expect(spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } }).stdout).toContain(`betterlink ${c}`)
    }
  })

  test('gives a folder an icon, shows it in the listing, and clears it', () => {
    const d = home()
    const folder = run(d, 'sidebar', 'add-folder', '--name', 'Docs').json.id as string
    const icon = () => run(d, 'sidebar', 'list').json[0].items[0].icon
    expect(run(d, 'sidebar', 'icon', 'set', folder.slice(0, 8), '--emoji', '🚀').code).toBe(0)
    expect(icon()).toEqual({ emoji: '🚀' })
    expect(run(d, 'sidebar', 'icon', 'set', folder, '--symbol', 'star.fill').code).toBe(0)
    expect(icon()).toEqual({ symbol: 'star.fill' })
    // The app checks a symbol against the Mac's own, and an emoji is one emoji.
    expect(run(d, 'sidebar', 'icon', 'set', folder, '--symbol', 'not.a.symbol.this.mac.has').code).not.toBe(0)
    expect(run(d, 'sidebar', 'icon', 'set', folder, '--emoji', 'ab').code).not.toBe(0)
    // One of the two.
    expect(run(d, 'sidebar', 'icon', 'set', folder).code).not.toBe(0)
    expect(run(d, 'sidebar', 'icon', 'set', folder, '--emoji', '🚀', '--symbol', 'star.fill').code).not.toBe(0)
    expect(icon()).toEqual({ symbol: 'star.fill' })
    expect(run(d, 'sidebar', 'icon', 'clear', folder).code).toBe(0)
    expect(icon()).toBeUndefined()
    // A saved link shows its site's icon, so it can't have one.
    const link = run(d, 'sidebar', 'add-link', '--url', 'https://example.com').json.id as string
    expect(run(d, 'sidebar', 'icon', 'set', link, '--emoji', '🚀').code).not.toBe(0)
    const llms = spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } }).stdout
    for (const c of ['sidebar icon set', 'sidebar icon clear']) expect(llms).toContain(`betterlink ${c}`)
  })

  test('opens and closes one folder, or every folder with --all', () => {
    const d = home()
    const docs = run(d, 'sidebar', 'add-folder', '--name', 'Docs').json.id as string
    expect(run(d, 'sidebar', 'add-folder', '--name', 'Inner', '--to', docs).code).toBe(0)
    expect(run(d, 'sidebar', 'add-folder', '--name', 'Work').code).toBe(0)
    const open = () => {
      const items = run(d, 'sidebar', 'list').json[0].items
      return [items[0].expanded, items[0].items[0].expanded, items[1].expanded]
    }
    expect(run(d, 'sidebar', 'expand', docs, '--open', 'off').code).toBe(0)
    expect(open()).toEqual([false, true, true])
    expect(run(d, 'sidebar', 'expand', '--all', '--open', 'off').code).toBe(0)
    expect(open()).toEqual([false, false, false])
    expect(run(d, 'sidebar', 'expand', '--all', '--open', 'on').code).toBe(0)
    expect(open()).toEqual([true, true, true])
    expect(run(d, 'sidebar', 'expand', docs, '--all', '--open', 'off').code).not.toBe(0)
    expect(run(d, 'sidebar', 'expand', '--open', 'off').code).not.toBe(0)
  })

  test('moves, files and deletes several at once, as the sidebar does for picked rows', () => {
    const d = home()
    const link = (name: string) => run(d, 'sidebar', 'add-link', '--url', `https://${name}.example`, '--title', name).json.id as string
    const [a, b, c] = [link('a'), link('b'), link('c')]
    const docs = run(d, 'sidebar', 'add-folder', '--name', 'Docs').json.id as string
    const shape = () => {
      const name = (i: any): string => (i.kind === 'folder' ? `${i.name}[${i.items.map(name).join(',')}]` : i.title)
      return run(d, 'sidebar', 'list').json[0].items.map(name)
    }
    // Several move together, in the order given.
    expect(run(d, 'sidebar', 'move', `${c},${a.slice(0, 8)}`, '--to', docs).code).toBe(0)
    expect(shape()).toEqual(['b', 'Docs[c,a]'])
    // All or none: a folder can't be a Favorite, so b stays too.
    expect(run(d, 'sidebar', 'move', `${b},${docs}`, '--to', 'favorites').code).not.toBe(0)
    expect(shape()).toEqual(['b', 'Docs[c,a]'])
    // A new folder takes things with it and stands where the first stood.
    expect(run(d, 'sidebar', 'add-folder', '--name', 'New', '--with', `${b},${a}`).code).toBe(0)
    expect(shape()).toEqual(['New[b,a]', 'Docs[c]'])
    // Several are deleted together; a folder with things in it still needs --withContents.
    expect(run(d, 'sidebar', 'remove', `${c},${docs}`).code).not.toBe(0) // Docs holds c
    expect(shape()).toEqual(['New[b,a]', 'Docs[c]'])
    expect(run(d, 'sidebar', 'remove', `${c},${docs}`, '--withContents').code).toBe(0)
    expect(shape()).toEqual(['New[b,a]'])
    const full = run(d, 'sidebar', 'remove', `${b},${run(d, 'sidebar', 'list').json[0].items[0].id}`)
    expect(full.code).not.toBe(0)
    expect(shape()).toEqual(['New[b,a]'])
    const llms = spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } }).stdout
    for (const c of ['tabs save', 'tabs reload', 'tabs mute']) expect(llms).toContain(`betterlink ${c}`)
    expect(run(d, 'tabs', 'save', 'twelve', '--folder', 'Later').code).not.toBe(0) // not a tab id
    expect(shape()).toEqual(['New[b,a]'])
  })

  // The app carries the Tabs extension and puts it in one folder (under
  // BETTERLINK_HOME here, so this never touches the one a browser loads).
  test('says where the Tabs extension is, after putting it there', () => {
    const d = home()
    const r = run(d, 'tabs', 'extension')
    expect(r.code).toBe(0)
    expect(r.json.path).toBe(join(d, 'tabs-extension'))
    expect(r.json.id).toBe('gjjllnebeeegbipppiclhlomdppbnljh')
    const shipped = JSON.parse(readFileSync(join(root, 'browser-extension/manifest.json'), 'utf8'))
    const placed = JSON.parse(readFileSync(join(d, 'tabs-extension', 'manifest.json'), 'utf8'))
    expect(r.json.version).toBe(shipped.version)
    expect(placed).toEqual(shipped)
    for (const f of ['background.js', 'bridge.js', 'reconnect.js', 'icons/128.png']) {
      expect(readFileSync(join(d, 'tabs-extension', f))).toEqual(readFileSync(join(root, 'browser-extension', f)))
    }
    // Only what the browser runs: no tests, no package.json.
    expect(existsSync(join(d, 'tabs-extension', 'tests'))).toBe(false)
    expect(existsSync(join(d, 'tabs-extension', 'package.json'))).toBe(false)
    // A second call changes nothing and says the same.
    expect(run(d, 'tabs', 'extension').json).toEqual(r.json)
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

  test('groups rules by profile and shows where another profile\'s rule comes first', () => {
    const d = home()
    const browser = chromium(d)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Profile 1', '--name', 'Work').code).toBe(0)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Default', '--name', 'Personal').code).toBe(0)
    // 1 example.com in Personal hides 2 app.example.com in Work;
    // 3 github.com/acme in Work is an exception to 4 github.com in Personal.
    for (const [kind, pattern, profile] of [['domain', 'example.com', 'Personal'], ['domain', 'app.example.com', 'Work'],
      ['startsWith', 'https://github.com/acme', 'Work'], ['domain', 'github.com', 'Personal']]) {
      expect(run(d, 'rules', 'add', '--kind', kind, '--pattern', pattern, '--profile', profile).code).toBe(0)
    }

    const groups = run(d, 'rules', 'profiles').json
    expect(groups.map((g: any) => [g.profileName, g.rules, g.positions, g.hidden]))
      .toEqual([['Work', 2, [2, 3], 1], ['Personal', 2, [1, 4], 0]])

    const work = run(d, 'rules', 'list', '--profile', 'Work').json
    expect(work.map((r: any) => [r.position, r.pattern])).toEqual([[2, 'app.example.com'], [3, 'https://github.com/acme']])
    expect(work[0].hiddenBy.position).toBe(1)
    expect(work[0].hiddenBy.example).toBe('https://app.example.com/')
    expect(work[1].hiddenBy).toBeNull()
    expect(work[1].checkedBefore.map((r: any) => r.position)).toEqual([4])

    // Moving the hidden rule above the one that hid it clears it.
    expect(run(d, 'rules', 'move', work[0].id, '--to', '1').code).toBe(0)
    expect(run(d, 'rules', 'profiles').json.map((g: any) => g.hidden)).toEqual([0, 0])
    expect(run(d, 'rules', 'list', '--browser', browser).code).not.toBe(0)
  })

  test('a rule can name more than one profile, and opens in the first this Mac has', () => {
    const d = home()
    const browser = chromium(d)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Profile 1', '--name', 'Work').code).toBe(0)
    expect(run(d, 'profiles', 'add', '--browser', browser, '--directory', 'Default', '--name', 'Personal').code).toBe(0)
    // A profile in a browser this Mac doesn't have, as a rule synced from another Mac names it.
    const installed = run(d, 'browsers', 'list').json.map((b: any) => b.name)
    const missing = ['Wavebox', 'Yandex', 'Helium', 'Comet'].find((b) => !installed.includes(b))!
    expect(run(d, 'profiles', 'add', '--browser', missing, '--directory', 'Default', '--name', 'Home').code).toBe(0)
    expect(run(d, 'rules', 'add', '--kind', 'domain', '--pattern', 'example.com', '--profile', 'Home',
      '--then', `${browser}:Work`, '--then', 'Personal').code).toBe(0)
    const [rule] = run(d, 'rules', 'list').json
    expect(rule.profileName).toBe('Home')
    expect(rule.backups.map((b: any) => b.profileName)).toEqual(['Work', 'Personal'])
    expect(rule.opensIn.profileName).toBe('Work')
    expect(run(d, 'rules', 'profiles').json.map((g: any) => g.profileName)).toEqual(['Work'])
    expect(run(d, 'test', 'https://example.com/').json.profileName).toBe('Work')

    expect(run(d, 'rules', 'update', rule.id, '--then', 'none').code).toBe(0)
    expect(run(d, 'rules', 'list').json[0].backups).toEqual([])
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
    // Refused before anything is saved: no side but left and right, no Safari.
    expect(run(d, 'sidebar', 'settings', 'set', '--side', 'auto').code).not.toBe(0)
    expect(run(d, 'sidebar', 'settings', 'set', '--browsers', 'Safari').code).not.toBe(0)
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

  test('updates set --install off sends only install: false', () => {
    const d = home()
    const fake = join(d, 'fake-app')
    writeFileSync(fake, `#!/bin/sh\nprintf '%s %s' "$2" "$3" > '${join(d, 'sent.txt')}'\necho '{"version":1,"ok":true}'\n`)
    chmodSync(fake, 0o755)
    const r = spawnSync('bun', [bin, 'updates', 'set', '--install', 'off', '--json'], {
      encoding: 'utf8', env: { ...process.env, BETTERLINK_HOME: d, BETTERLINK_APP_BINARY: fake },
    })
    expect(r.status).toBe(0)
    const [command, json] = readFileSync(join(d, 'sent.txt'), 'utf8').split(' ')
    expect(command).toBe('updates.set')
    expect(JSON.parse(json)).toEqual({ install: false })
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

  // The tour (docs/tour.md): what the window shows, an agent can read, mark
  // seen and put back. Nothing here opens a window: the temporary settings
  // folder has no running app.
  test('the tour: status, done, reset and what is new', () => {
    const d = home()
    const fresh = run(d, 'tour', 'status').json
    expect(fresh.welcomed).toBe(false)
    expect(fresh.showsNext).toBe('welcome')
    expect(fresh.new).toEqual([])
    // A step that does something says how an agent does the same (a step
    // that only explains has neither a command nor a reason for none).
    const steps = fresh.topics.flatMap((t: any) => t.steps)
    const commands = steps.map((s: any) => s.command).filter(Boolean)
    expect(commands.length).toBeGreaterThan(10)
    for (const c of commands) expect(c).toStartWith('betterlink ')
    for (const s of steps) expect(s.state).toBe('new')
    // Nothing is new before the first run.
    expect(run(d, 'tour', 'new').json.shown).toBe(false)

    const done = run(d, 'tour', 'done').json
    expect(done.welcomed).toBe(true)
    expect(done.showsNext).toBe('nothing')
    // A step for something this Mac lacks (Dia, a Chromium browser) is left for the day it applies.
    expect(done.topics.flatMap((t: any) => t.steps).every((s: any) => s.state === (s.applies ? 'seen' : 'new'))).toBe(true)
    expect(run(d, 'tour', 'new').json.shown).toBe(false)

    // One step put back is What's New, and only that.
    const back = run(d, 'tour', 'reset', '--step', 'link-rules').json
    expect(back.new).toEqual(['link-rules'])
    expect(back.showsNext).toBe('new')
    expect(run(d, 'tour', 'new').json.shown).toBe(true)
    expect(run(d, 'tour', 'done', '--topic', 'link-rules').json.new).toEqual([])

    expect(run(d, 'tour', 'show', '--topic', 'feedback').json.shown).toBe(true)
    // A bare word is refused, not dropped: `tour reset link-rules` must not forget everything.
    for (const bad of [['show', '--topic', 'nope'], ['done', '--step', 'nope'], ['reset', '--step', 'welcome', '--topic', 'welcome'],
      ['reset', 'link-rules'], ['done', 'sidebar'], ['show', 'sidebar']]) {
      const r = run(d, 'tour', ...bad)
      expect(r.code).not.toBe(0)
    }
    expect(run(d, 'tour', 'status').json.welcomed).toBe(true)
    // All of it put back: the first run again.
    const again = run(d, 'tour', 'reset').json
    expect(again.welcomed).toBe(false)
    expect(again.showsNext).toBe('welcome')
  })

  // The commands the tour's steps name are in the list an agent reads
  // (scripts/gen-tour.py checks each step's command and options exist).
  test('the tour, Sync and tab helper commands are listed for agents', () => {
    const llms = spawnSync('bun', [bin, '--llms'], { encoding: 'utf8', env: { ...process.env, BETTERLINK_APP_BINARY: app } }).stdout
    for (const c of ['tour status', 'tour show', 'tour new', 'tour done', 'tour reset', 'sync get', 'sync set', 'sync add', 'sync merge', 'sync paused', 'sync resolve', 'sync history', 'sync restore', 'tabs helpers', 'tabs setup', 'changelog list']) {
      expect(llms).toContain(`betterlink ${c}`)
    }
  })

  // The changelog built into the app (scripts/gen-changelog.py), the same
  // list the Changelog page shows. A clone without tags builds an empty one.
  test('changelog: the releases this copy was built with, newest first', () => {
    const d = home()
    const all = run(d, 'changelog', 'list')
    expect(all.code).toBe(0)
    expect(typeof all.json.installed).toBe('string')
    const versions: string[] = all.json.releases.map((r: any) => r.version)
    const key = (v: string) => v.split('.').map(Number)
    const newer = (a: string, b: string) => {
      const [x, y] = [key(a), key(b)]
      for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i]
      return false
    }
    for (let i = 1; i < versions.length; i++) expect(newer(versions[i - 1], versions[i])).toBe(true)
    for (const r of all.json.releases) {
      expect(r.date).toMatch(/^\d{4}-\d{2}-\d{2}$/)
      for (const c of r.changes) expect(typeof c.text).toBe('string')
    }
    if (versions.length >= 2) {
      expect(run(d, 'changelog', 'list', '--limit', '1').json.releases.map((r: any) => r.version)).toEqual([versions[0]])
      expect(run(d, 'changelog', 'list', '--since', versions[1]).json.releases.map((r: any) => r.version)).toEqual([versions[0]])
    }
    expect(run(d, 'changelog', 'list', '--since', 'soon').code).not.toBe(0)
  })

  test('sync: a folder, what syncs, and off', () => {
    const d = home()
    expect(run(d, 'sync', 'get').json).toMatchObject({ on: false, folder: null })
    const folder = mkdtempSync(join(tmpdir(), 'bl-sync-'))
    const on = run(d, 'sync', 'set', '--folder', folder, '--global', 'off')
    expect(on.code).toBe(0)
    const now = run(d, 'sync', 'get').json
    expect(now.on).toBe(true)
    expect(realpathSync(now.folder)).toBe(realpathSync(folder))
    expect(now.global).toBe(false)
    expect(now.macs).toEqual([])   // no other Mac has written into the new folder

    // What of one Sidebar Profile syncs.
    expect(run(d, 'sidebar', 'profiles', 'add', '--name', 'Work').code).toBe(0)
    expect(run(d, 'sync', 'set', '--profile', 'Work', '--parts', 'favorites,name').code).toBe(0)
    expect(run(d, 'sync', 'get').json.profiles).toEqual([expect.objectContaining({ name: 'Work', favorites: true, folders: false, appearance: true })])
    expect(run(d, 'sync', 'set', '--profile', 'Work', '--parts', 'none').code).toBe(0)
    expect(run(d, 'sync', 'get').json.profiles).toEqual([])

    for (const bad of [['--folder', join(folder, 'missing')], ['--folder', folder, '--off', 'on'], ['--parts', 'favorites'], ['--profile', 'Work', '--parts', 'colour'], ['--profile', 'Work', '--parts', ','], []]) {
      expect(run(d, 'sync', 'set', ...bad).code).not.toBe(0)
    }
    expect(run(d, 'sync', 'set', '--off', 'on').code).toBe(0)
    expect(run(d, 'sync', 'get').json).toMatchObject({ on: false, folder: null })
  })

  // The hold and the history are filled by the app's sync (SyncSafetyTests);
  // here, what the commands say and refuse when there is nothing yet.
  test('sync: paused, resolve, history and restore with nothing to answer', () => {
    const d = home()
    expect(run(d, 'sync', 'paused').json).toEqual({ paused: false })
    expect(run(d, 'sync', 'resolve', '--choice', 'keep').code).not.toBe(0)
    expect(run(d, 'sync', 'resolve', '--choice', 'maybe').code).not.toBe(0)
    expect(run(d, 'sync', 'history').json).toEqual([])
    expect(run(d, 'sync', 'restore', '1234').code).not.toBe(0)
  })

  // Read only: setting a helper up writes into the browser's own folder,
  // which BETTERLINK_HOME does not move.
  test('tab helpers: lists the browsers, and refuses one it does not know', () => {
    const d = home()
    const list = run(d, 'tabs', 'helpers').json.browsers
    for (const b of list) {
      expect(['setUp', 'notSetUp', 'pointsElsewhere']).toContain(b.helper)
      // Which profiles have the Tabs extension connected, as the Sidebar page shows under the row.
      expect(['notRunning', 'none', 'connected', 'outdated']).toContain(b.extension)
      expect(Array.isArray(b.profiles)).toBe(true)
    }
    expect(run(d, 'tabs', 'setup', '--browser', 'No Such Browser').code).not.toBe(0)
    expect(run(d, 'tabs', 'setup', '--browser', 'Safari').code).not.toBe(0)
    // With a temporary settings folder it refuses a real browser too, before writing anything.
    for (const b of list) {
      const r = run(d, 'tabs', 'setup', '--browser', b.browser)
      expect(r.code).not.toBe(0)
      expect(r.stdout + r.stderr).toContain('BETTERLINK_HOME')
    }
    expect(run(d, 'tabs', 'helpers').json.browsers).toEqual(list)
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
