/**
 * LLM-Brain: Neural Expansion page for Hermes Desktop (the desktop half of
 * the llm-brain package). Hermes Desktop does not show dashboard plugin tabs;
 * it loads `plugins/<name>/desktop/plugin.js` instead.
 *
 * The page asks the connected backend's llm-brain plugin API
 * (`/api/plugins/llm-brain/view`, the same one the dashboard tab uses) for the
 * self-contained HTML and shows it in a sandboxed iframe: scripts run, but
 * there is no same-origin access and the page's CSP forbids network access.
 * Nothing is written to disk on the desktop side.
 */
import { host, PALETTE_AREA, ROUTES_AREA, SIDEBAR_NAV_AREA } from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

const PATH = '/neural-expansion'

function makePage(rest) {
  return function NeuralExpansionPage() {
    const [status, setStatus] = useState(null)
    const [mode, setMode] = useState('demo')
    const [html, setHtml] = useState('')
    const [error, setError] = useState('')
    const [projects, setProjects] = useState([])
    const [project, setProject] = useState('')
    const [progress, setProgress] = useState('')
    const token = useRef(0)

    // "View all": the backend builds every project in parallel; poll its progress.
    const loadAll = (mine) => {
      setProgress('Loading all projects…')
      rest('/view-all/start')
        .then(started => {
          const poll = () => {
            if (token.current !== mine) return
            rest(`/view-all/status?job=${encodeURIComponent(started.job)}`)
              .then(r => {
                if (token.current !== mine) return
                if (r && r.status === 'ok') {
                  setProgress(r.skipped ? `${r.total - r.skipped} of ${r.total} projects loaded (${r.skipped} skipped)` : '')
                  setHtml(r.html || '')
                } else {
                  setProgress(`Loading all projects… ${(r && r.done) || 0}/${(r && r.total) || started.total}` + (r && r.skipped ? ` (${r.skipped} skipped)` : ''))
                  setTimeout(poll, 1200)
                }
              })
              .catch(e => { if (token.current === mine) { setProgress(''); setError(String((e && e.message) || e)) } })
          }
          poll()
        })
        .catch(e => { if (token.current === mine) { setProgress(''); setError(String((e && e.message) || e)) } })
    }

    const load = (next, chosen = project) => {
      const mine = ++token.current
      setMode(next)
      setError('')
      setHtml('')
      setProgress('')
      if (next === 'export' && chosen === '__all__') return loadAll(mine)
      const query = next === 'export' && chosen ? `&project=${encodeURIComponent(chosen)}` : ''
      rest(`/view?mode=${encodeURIComponent(next)}${query}`)
        .then(r => { if (token.current === mine) setHtml((r && r.html) || '') })
        .catch(e => { if (token.current === mine) setError(String((e && e.message) || e)) })
    }

    useEffect(() => () => { token.current += 1 }, [])

    useEffect(() => {
      rest('/status').then(setStatus).catch(e => setError(String((e && e.message) || e)))
      rest('/projects').then(r => setProjects((r && r.projects) || [])).catch(() => setProjects([]))
      load('demo')
    }, [])

    const exportEnabled = Boolean(status && status.export_enabled)
    const button = (label, next, disabled, title) =>
      jsx('button', {
        type: 'button',
        disabled,
        title,
        onClick: () => load(next),
        style: {
          padding: '4px 10px',
          borderRadius: '6px',
          border: '1px solid var(--ui-border, #555)',
          background: mode === next ? 'var(--ui-bg-tertiary, #333)' : 'transparent',
          color: 'inherit',
          opacity: disabled ? 0.5 : 1,
          cursor: disabled ? 'not-allowed' : 'pointer'
        },
        children: label
      })

    return jsxs('div', {
      style: { display: 'flex', flexDirection: 'column', gap: '10px', height: '100%', padding: '12px', boxSizing: 'border-box' },
      children: [
        jsxs('div', {
          style: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' },
          children: [
            jsx('strong', { children: 'Neural Expansion' }),
            button('Synthetic demo', 'demo', false, 'Bundled synthetic data'),
            button('My brain', 'export', !exportEnabled,
              exportEnabled ? "This profile's brain, principal-filtered, read-only"
                : 'Set "neural_expansion_export": true in llm-brain.json on the Hermes host'),
            exportEnabled && projects.length
              ? jsx('select', {
                  value: project,
                  title: 'Project (records / relations / pending review)',
                  onChange: e => { setProject(e.target.value); load('export', e.target.value) },
                  style: { padding: '3px 6px', borderRadius: '6px', background: 'transparent', color: 'inherit', border: '1px solid var(--ui-border, #555)' },
                  children: [jsx('option', { value: '', children: 'Detected project' }, ''),
                    jsx('option', { value: '__all__', children: `View all (All projects: ${projects.reduce((n, p) => n + p.records, 0)} records, ${projects.reduce((n, p) => n + p.pending_review, 0)} pending)` }, '__all__')].concat(projects.map(p =>
                    jsx('option', { value: p.project_id, children: `${p.alias} (${p.records} records, ${p.relations} relations, ${p.pending_review} pending)` }, p.project_id)))
                })
              : null,
            jsx('span', { style: { opacity: 0.7 }, children: mode === 'demo' ? 'Synthetic data only.' : 'Principal-filtered snapshot with label lineage.' }),
            progress ? jsx('span', { role: 'status', style: { opacity: 0.85 }, children: progress }) : null,
            error ? jsx('span', { style: { color: '#d66' }, children: error }) : null
          ]
        }),
        html
          ? jsx('iframe', {
              title: 'Neural Expansion',
              sandbox: 'allow-scripts',
              srcDoc: html,
              style: { flex: 1, minHeight: '60vh', width: '100%', border: 0, borderRadius: '8px' }
            })
          : null
      ]
    })
  }
}

export default {
  id: 'llm-brain',
  name: 'LLM-Brain',
  register(ctx) {
    const Page = makePage(ctx.rest)
    ctx.registerMany([
      { id: 'page', area: ROUTES_AREA, data: { path: PATH }, render: () => jsx(Page, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, order: 60, data: { codicon: 'graph', label: 'Neural Expansion', path: PATH } },
      {
        id: 'open',
        area: PALETTE_AREA,
        data: {
          id: 'llm-brain.neuralExpansion',
          label: 'Open Neural Expansion',
          keywords: ['neural', 'expansion', 'memory', 'brain', 'graph', 'lineage'],
          run: () => host.navigate(PATH)
        }
      }
    ])
  }
}
