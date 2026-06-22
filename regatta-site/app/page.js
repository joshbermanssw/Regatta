const GITHUB_URL = "https://github.com/joshbermanssw/Regatta";

function FleetMark({ size = 28 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 128 128"
      fill="none"
      aria-hidden="true"
      className="mark"
    >
      <path d="M30 52 L30 94 L50 94 Z" fill="var(--azimuth)" fillOpacity="0.32" />
      <path d="M54 38 L54 94 L74 94 Z" fill="var(--azimuth)" fillOpacity="0.58" />
      <path d="M80 18 L80 94 L110 94 Z" fill="var(--azimuth)" />
      <path className="burgee" d="M80 16 L99 21 L80 26 Z" fill="var(--wake)" />
      <rect x="22" y="98" width="94" height="3" rx="1.5" fill="var(--azimuth)" />
      <rect x="28" y="105" width="40" height="2" rx="1" fill="var(--azimuth)" fillOpacity="0.4" />
    </svg>
  );
}

const PILLARS = [
  {
    tag: "01 · controller",
    title: "Brain + fleet",
    body:
      "A persistent controller agent spawns and supervises worker subagents as real, watchable terminals — each in its own git worktree, off in a separate space so they never clutter your work.",
  },
  {
    tag: "02 · run-to-done",
    title: "Loops",
    body:
      "Run an agent until a deterministic or brain-judged exit condition is met — tests pass, CI is green, the job is actually done — with hard safety caps so nothing runs away.",
  },
  {
    tag: "03 · the log",
    title: "Memory",
    body:
      "A hierarchical, self-partitioning fact store with dedicated allocator and archivist agents. It compounds what the fleet learns. Auto-built, hand-correctable.",
  },
  {
    tag: "04 · into harbor",
    title: "PR shepherding",
    body:
      "Hand off a finished PR and move on. Regatta watches CI failures and reviewer threads after you've left, and acts — escorting the work the last mile home.",
  },
];

const MODEL = [
  { term: "Brain", def: "the mind on the deck, directing the race" },
  { term: "Fleet", def: "the boats racing at once" },
  { term: "Worker", def: "one boat, crewed in its own worktree" },
  { term: "Loop", def: "sailing the legs until you cross the line" },
  { term: "Shepherd", def: "escorting a PR safely into harbor" },
  { term: "Memory", def: "the ship's log and charts" },
];

const FLEET_ROWS = [
  { id: "worker-01", task: "fix/auth-token", state: "running", signal: "run" },
  { id: "worker-02", task: "test/regatta-suite", state: "running", signal: "run" },
  { id: "worker-03", task: "refactor/rail-view", state: "queued", signal: "queue" },
  { id: "worker-04", task: "shepherd · pr #82", state: "landed", signal: "land" },
];

export default function Page() {
  return (
    <>
      <div className="chart" aria-hidden="true" />

      <header className="nav">
        <a className="brand" href="#top" aria-label="Regatta home">
          <FleetMark size={26} />
          <span className="brand-word">Regatta</span>
        </a>
        <nav className="nav-links">
          <a href="#pillars">Pillars</a>
          <a href="#model">The model</a>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            GitHub ↗
          </a>
        </nav>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <p className="eyebrow">// command deck for AI coding agents</p>
            <h1 className="display">
              Hand it off.
              <br />
              <span className="accent">Watch it land.</span>
            </h1>
            <p className="lede">
              A persistent <strong>brain</strong> sits beside your work. Hand it a
              tab, a PR, or a task and it races a <strong>fleet</strong> of agent
              terminals — each in its own worktree — looping them until the job is
              actually done.
            </p>
            <div className="cta-row">
              <a className="btn btn-primary" href={GITHUB_URL} target="_blank" rel="noreferrer">
                View on GitHub
              </a>
              <a className="btn btn-ghost" href="#pillars">
                See how it works
              </a>
            </div>
            <p className="fineprint">
              A fork of cmux · native Swift · macOS · GPL-3.0-or-later
            </p>
          </div>

          <aside className="readout" aria-label="Fleet status (illustrative)">
            <div className="readout-head">
              <span className="readout-title">
                <span className="dot dot-run" /> FLEET · racing
              </span>
              <span className="readout-cap">cap 4/4</span>
            </div>
            <ul className="readout-list">
              {FLEET_ROWS.map((r) => (
                <li key={r.id} className="readout-row">
                  <FleetMark size={14} />
                  <span className="r-id">{r.id}</span>
                  <span className="r-task">{r.task}</span>
                  <span className={`r-state state-${r.signal}`}>
                    <span className={`dot dot-${r.signal}`} />
                    {r.state}
                  </span>
                </li>
              ))}
            </ul>
            <div className="readout-foot">
              <span>leg 3 · windward mark</span>
              <span>loop guard: on</span>
            </div>
          </aside>
        </section>

        <section id="pillars" className="pillars">
          <header className="section-head">
            <p className="eyebrow">// what it does</p>
            <h2 className="display section-title">Four instruments, one deck.</h2>
          </header>
          <div className="pillar-grid">
            {PILLARS.map((p) => (
              <article key={p.title} className="card">
                <p className="card-tag">{p.tag}</p>
                <h3 className="card-title">{p.title}</h3>
                <p className="card-body">{p.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section id="model" className="model">
          <header className="section-head">
            <p className="eyebrow">// the nautical model</p>
            <h2 className="display section-title">The vocabulary is the system.</h2>
            <p className="section-sub">
              Every term maps a Regatta concept to its nautical logic. Read it like a
              course, bow to stern.
            </p>
          </header>
          <ol className="course">
            {MODEL.map((m, i) => (
              <li key={m.term} className="leg">
                <span className="leg-no">{String(i + 1).padStart(2, "0")}</span>
                <span className="leg-term">{m.term}</span>
                <span className="leg-def">{m.def}</span>
              </li>
            ))}
          </ol>
        </section>

        <section className="closer">
          <h2 className="display closer-title">
            Delegate the work.
            <br />
            <span className="accent">Keep the helm.</span>
          </h2>
          <a className="btn btn-primary" href={GITHUB_URL} target="_blank" rel="noreferrer">
            View on GitHub ↗
          </a>
        </section>
      </main>

      <footer className="foot">
        <div className="foot-brand">
          <FleetMark size={20} />
          <span>Regatta</span>
        </div>
        <p className="foot-note">
          A fork of cmux. Orchestration patterns borrowed from ARMADA. Native Swift,
          GPL-3.0-or-later.
        </p>
        <div className="foot-links">
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            GitHub
          </a>
          <a href="https://github.com/manaflow-ai/cmux" target="_blank" rel="noreferrer">
            cmux
          </a>
        </div>
      </footer>
    </>
  );
}
