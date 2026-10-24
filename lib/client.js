/**
 * dsh-lanbuddy-pair — browser half.
 *
 * One settings page: 「扫码配对」. It asks `/lanbuddy/pair/info` what the host
 * serves on, then renders the QR only when that address is reachable from a
 * phone. A loopback-only instance (desktop app / local dsh) gets an explicit
 * warning instead of a QR that could never connect.
 */
window.__ModuleLoader__.load({
  id: 'dsh-lanbuddy-pair',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const React = require('react')
    const { jsx, jsxs } = require('react/jsx-runtime')

    const card = {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '10px',
      padding: '22px 16px',
    }
    const title = { fontSize: '15px', fontWeight: 600, color: '#1c1c1e' }
    const hint = { fontSize: '12.5px', color: '#8e8e93', textAlign: 'center' }
    const frame = {
      background: '#fff',
      border: '1px solid #e5e5ea',
      borderRadius: '14px',
      padding: '10px',
      lineHeight: 0,
    }
    const warn = {
      maxWidth: '420px',
      color: '#8a5300',
      background: '#fff6e5',
      border: '1px solid #ffe0a3',
      borderRadius: '10px',
      padding: '12px 14px',
      fontSize: '13px',
      lineHeight: 1.5,
      textAlign: 'left',
    }
    const urlText = {
      wordBreak: 'break-all',
      font: '12px/1.4 ui-monospace,Consolas,monospace',
      color: '#8e8e93',
      textAlign: 'center',
    }
    const dangerButton = {
      marginTop: '4px',
      border: '1px solid #ffd0cc',
      background: '#fff5f4',
      color: '#e5453c',
      borderRadius: '10px',
      padding: '8px 14px',
      fontSize: '13px',
      cursor: 'pointer',
    }

    function PairSection() {
      const [info, setInfo] = React.useState(null)
      const [error, setError] = React.useState(null)
      const [revoked, setRevoked] = React.useState(null)
      const [revoking, setRevoking] = React.useState(false)

      const revokeAll = React.useCallback(async () => {
        if (!window.confirm('解除所有设备后，手机都需要重新扫码；且要重启 dsh 才会生效。继续？')) return
        setRevoking(true)
        try {
          const response = await fetch('/lanbuddy/devices/revoke', {
            method: 'POST',
            credentials: 'same-origin',
          })
          const body = await response.json().catch(() => ({}))
          setRevoked(response.ok && body.ok
            ? '已解除全部设备。重启 dsh 后生效，手机需重新扫码配对。'
            : `解除失败（HTTP ${response.status}）`)
        } catch (reason) {
          setRevoked(`解除失败：${String(reason)}`)
        } finally {
          setRevoking(false)
        }
      }, [])

      React.useEffect(() => {
        let alive = true
        fetch('/lanbuddy/pair/info', { credentials: 'same-origin' })
          .then((response) => response.ok
            ? response.json()
            : Promise.reject(new Error(`HTTP ${response.status}`)))
          .then((value) => { if (alive) setInfo(value) })
          .catch((reason) => { if (alive) setError(String(reason)) })
        return () => { alive = false }
      }, [])

      if (error !== null) {
        return jsxs('div', {
          style: card,
          children: [
            jsx('div', { style: title, children: '无法读取配对信息' }),
            jsx('div', { style: hint, children: error }),
          ],
        })
      }

      if (info === null) {
        return jsx('div', {
          style: { ...hint, padding: '28px 12px' },
          children: '正在读取配对信息…',
        })
      }

      if (info.loopback) {
        const lanReachable = info.lan !== null && info.lan !== undefined && info.lan.reachable
        if (!lanReachable) {
          return jsxs('div', {
            style: card,
            children: [
              jsx('div', { style: title, children: '手机连不上这个实例' }),
              jsxs('div', {
                style: warn,
                children: [
                  '桌面应用只监听 ',
                  jsx('code', { children: `${info.host}${info.port === null ? '' : `:${info.port}`}` }),
                  '（本机回环地址），手机通过 WiFi 访问不到。' +
                  '请先启动陪伴进程（它监听局域网地址，和桌面共用同一批会话），' +
                  '再回到这里扫码。',
                ],
              }),
              jsx('div', { style: urlText, children: info.url }),
            ],
          })
        }
        return jsxs('div', {
          style: card,
          children: [
            jsx('div', { style: title, children: '用手机扫码连接' }),
            jsx('div', {
              style: frame,
              children: jsx('img', {
                src: '/lanbuddy/pair/qr.svg',
                width: 248,
                height: 248,
                alt: '配对二维码',
                style: { display: 'block' },
              }),
            }),
            jsx('div', {
              style: hint,
              children:
                `二维码指向局域网实例 ${info.lan.origin}（与桌面应用共用同一批会话）。` +
                '手机需与 PC 连同一个 WiFi。',
            }),
          ],
        })
      }

      return jsxs('div', {
        style: card,
        children: [
          jsx('div', { style: title, children: '用手机扫码连接' }),
          jsx('div', {
            style: frame,
            children: jsx('img', {
              src: '/lanbuddy/pair/qr.svg',
              width: 248,
              height: 248,
              alt: '配对二维码',
              style: { display: 'block' },
            }),
          }),
          jsx('div', {
            style: hint,
            children: '手机与这台 PC 连同一个 WiFi；二维码每次进程启动自动更新。',
          }),
          jsx('button', {
            type: 'button',
            style: dangerButton,
            disabled: revoking,
            onClick: revokeAll,
            children: revoking ? '正在解除…' : '解除所有设备',
          }),
          revoked === null
            ? null
            : jsx('div', { style: { ...hint, color: '#8a5300' }, children: revoked }),
        ],
      })
    }

    const inject = ['slots']

    function apply(ctx) {
      ctx.effect(() => ctx.slots.inject('settings.section', () => ctx.slots.register({
        name: 'settings.section',
        id: 'lanbuddy-pair',
        order: 90,
        label: () => '扫码配对',
      }, PairSection)), 'lanbuddy-pair: settings page')
    }

    exports.inject = inject
    exports.apply = apply
    return module.exports
  },
})
