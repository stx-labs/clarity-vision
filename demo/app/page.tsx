"use client";

import { useCallback, useEffect, useRef, useState } from "react";

const slideTitles = [
  "A clean engine boundary",
  "Why change the shape?",
  "The four owners",
  "Repository map",
  "contract-call?: evaluator",
  "Cross-engine dispatch",
  "Classifying consensus gates",
  "What this design buys us",
  "Evidence and the path to Clarity 7",
] as const;

const totalSlides = slideTitles.length;

function Label({ children, tone = "blue" }: { children: React.ReactNode; tone?: "blue" | "red" | "green" | "ink" }) {
  return <span className={`label label-${tone}`}>{children}</span>;
}

function FileTag({ children }: { children: React.ReactNode }) {
  return <code className="file-tag">{children}</code>;
}

export default function Home() {
  const [current, setCurrent] = useState(0);
  const [overview, setOverview] = useState(false);
  const touchStart = useRef<number | null>(null);

  const goTo = useCallback((index: number) => {
    const next = Math.max(0, Math.min(totalSlides - 1, index));
    setCurrent(next);
    setOverview(false);
    window.history.replaceState(null, "", `#slide-${next + 1}`);
  }, []);

  const advance = useCallback(() => goTo(current + 1), [current, goTo]);
  const retreat = useCallback(() => goTo(current - 1), [current, goTo]);

  useEffect(() => {
    const match = window.location.hash.match(/^#slide-(\d+)$/);
    if (match) {
      const requested = Number(match[1]) - 1;
      if (requested >= 0 && requested < totalSlides) {
        const frame = window.requestAnimationFrame(() => setCurrent(requested));
        return () => window.cancelAnimationFrame(frame);
      }
    }
  }, []);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target?.matches("input, textarea, select, [contenteditable='true']")) return;
      if (["ArrowRight", "PageDown", " "].includes(event.key)) {
        event.preventDefault();
        advance();
      } else if (["ArrowLeft", "PageUp"].includes(event.key)) {
        event.preventDefault();
        retreat();
      } else if (event.key === "Home") {
        event.preventDefault();
        goTo(0);
      } else if (event.key === "End") {
        event.preventDefault();
        goTo(totalSlides - 1);
      } else if (event.key.toLowerCase() === "o") {
        event.preventDefault();
        setOverview((value) => !value);
      } else if (event.key === "Escape") {
        setOverview(false);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [advance, goTo, retreat]);

  return (
    <main
      className="deck"
      onTouchStart={(event) => { touchStart.current = event.changedTouches[0]?.clientX ?? null; }}
      onTouchEnd={(event) => {
        if (touchStart.current === null) return;
        const distance = (event.changedTouches[0]?.clientX ?? touchStart.current) - touchStart.current;
        touchStart.current = null;
        if (distance < -55) advance();
        if (distance > 55) retreat();
      }}
    >
      <header className="deck-header">
        <button className="brand" onClick={() => goTo(0)} aria-label="Go to first slide">
          <span>C6</span>
          <b>Clarity extraction</b>
        </button>
        <div className="section-name">
          <span>{String(current + 1).padStart(2, "0")}</span>
          <p>{slideTitles[current]}</p>
        </div>
        <button className="overview-button" onClick={() => setOverview(true)}>
          <span className="grid-icon" aria-hidden="true">⊞</span> Overview
        </button>
      </header>

      <aside className="slide-rail" aria-label="Slide navigation">
        {slideTitles.map((title, index) => (
          <button
            key={title}
            className={current === index ? "active" : ""}
            onClick={() => goTo(index)}
            aria-label={`Slide ${index + 1}: ${title}`}
            aria-current={current === index ? "step" : undefined}
          >
            <span>{String(index + 1).padStart(2, "0")}</span>
            <i />
          </button>
        ))}
      </aside>

      <div className="slide-stage" aria-live="polite">
        <article className={`slide title-slide ${current === 0 ? "active" : ""}`} aria-hidden={current !== 0}>
          <div className="slide-inner title-grid">
            <div>
              <Label tone="green">ENGINE REVISION 1 · TECHNICAL WALKTHROUGH</Label>
              <h1>A clean engine<br />boundary for <em>Clarity.</em></h1>
              <p className="standfirst">How Clarity 6 became a separately owned interpreter—without giving up historical replay, mixed-version calls, or shared consensus state.</p>
            </div>
            <div className="title-model">
              <div><small>HOST</small><strong>selects revisions</strong></div>
              <span>→</span>
              <div className="accent"><small>ENGINE</small><strong>owns semantics</strong></div>
              <span>→</span>
              <div><small>KERNEL</small><strong>shares state</strong></div>
            </div>
            <div className="title-footer">
              <p>Use <kbd>←</kbd> <kbd>→</kbd> or swipe to navigate</p>
              <button onClick={advance}>Begin walkthrough <span>→</span></button>
            </div>
          </div>
        </article>

        <article className={`slide ${current === 1 ? "active" : ""}`} aria-hidden={current !== 1}>
          <div className="slide-inner">
            <Label tone="red">THE ORIGINAL PRESSURE</Label>
            <h2>Protocol history had become interpreter structure.</h2>
            <div className="problem-grid">
              <div className="code-window">
                <div className="window-bar"><span /><span /><span /><b>legacy evaluator</b></div>
                <pre><code>{"match clarity_version { … }\n\nif epoch >= Epoch40 {\n    map_fixed(args)\n} else {\n    map_legacy(args)\n}\n\nsanitize(value, epoch)\nframe.commit(epoch)"}</code></pre>
              </div>
              <div className="problem-list">
                <div><b>01</b><h3>Every change touches history</h3><p>Reviewers must prove that new work cannot disturb old epoch/version branches.</p></div>
                <div><b>02</b><h3>State doubles as policy</h3><p>A live block epoch flows deep enough to select evaluator algorithms.</p></div>
                <div><b>03</b><h3>The matrix is implicit</h3><p>Language, engine revision, kernel behavior, and host policy are conflated.</p></div>
              </div>
            </div>
            <blockquote>Complexity was unavoidable. Its ownership was not.</blockquote>
          </div>
        </article>

        <article className={`slide ${current === 2 ? "active" : ""}`} aria-hidden={current !== 2}>
          <div className="slide-inner">
            <Label>The separation model</Label>
            <h2>Four decisions. Four explicit owners.</h2>
            <div className="owner-grid">
              <section><span>01</span><small>CONTRACT</small><h3>Language version</h3><code>ClarityVersion::Clarity6</code><p>Defines syntax, type rules, and language surface for newly deployed code.</p></section>
              <section><span>02</span><small>HOST MANIFEST</small><h3>Engine revision</h3><code>EngineRevision::Clarity6V1</code><p>Selects the concrete interpreter build for the current epoch and contract language.</p></section>
              <section><span>03</span><small>HOST → KERNEL</small><h3>Kernel ruleset</h3><code>KernelRuleset::V4</code><p>Controls shared serialization and transaction behavior that all engines must agree on.</p></section>
              <section><span>04</span><small>STACKSLIB</small><h3>Host policy</h3><code>epoch / post-conditions / chain data</code><p>Owns activation, transaction validity, receipts, and data supplied by the chain.</p></section>
            </div>
            <div className="formula-strip"><code>(current epoch, contract language)</code><span>→</span><code>engine revision</code><b>+</b><code>kernel ruleset</code></div>
          </div>
        </article>

        <article className={`slide ${current === 3 ? "active" : ""}`} aria-hidden={current !== 3}>
          <div className="slide-inner">
            <Label tone="ink">Repository map</Label>
            <h2>The new boundary is visible in the tree.</h2>
            <div className="tree-layout">
              <pre className="directory-tree"><code>
                <span className="tree-root">stacks-core/</span>
                <span className="tree-block tree-legacy"><strong>├── clarity/                  frozen legacy engine</strong></span>
                <span className="tree-block tree-shared"><strong>├── clarity-kernel/           shared ABI + state</strong>{`
│   └── src/
│       ├── engine.rs         Engine / dispatcher ABI
│       ├── transaction.rs    rollback frames + call stack
│       ├── database/         consensus storage
│       ├── assets.rs         asset movement table
│       ├── costs/            cumulative metering
│       └── rules.rs          kernel rule identifiers`}</span>
                <span className="tree-block tree-revision"><strong>├── clarity-v6/               clean language engine</strong>{`
│   └── src/
│       ├── lib.rs            Clarity6Engine
│       ├── conformance.rs    legacy-oracle comparison
│       └── vm/
│           ├── ast/          parser pipeline
│           ├── analysis/     static checks
│           ├── functions/    evaluator builtins
│           ├── contexts.rs   runtime + nested calls
│           ├── clarity6.rs   asset/frame adapters
│           ├── database/     DB adapter
│           └── types/        type/value adapter`}</span>
                <span className="tree-block tree-host"><strong>└── stackslib/src/clarity_vm/</strong>{`
    └── engine.rs             epoch manifest + selection`}</span>
              </code></pre>
              <div className="tree-notes">
                <div><Label tone="red">legacy</Label><p>Historical branches remain available for replay, but new engine work does not edit them.</p></div>
                <div><Label tone="green">shared</Label><p>The kernel contains only state and behavior that must agree across engines.</p></div>
                <div><Label>revision-owned</Label><p>Clarity 6 owns its parser, analyzer, costs, evaluator, and adapters.</p></div>
                <div><Label tone="ink">host-owned</Label><p>Stackslib maps protocol epochs to engine and kernel revisions.</p></div>
              </div>
            </div>
          </div>
        </article>

        <article className={`slide ${current === 4 ? "active" : ""}`} aria-hidden={current !== 4}>
          <div className="slide-inner">
            <Label tone="red">Code flow · evaluator</Label>
            <h2>What happens when Clarity evaluates <code>contract-call?</code>?</h2>
            <div className="code-flow-grid">
              <div className="source-card">
                <FileTag>clarity-v6/src/vm/functions/database.rs</FileTag>
                <pre><code>{`pub fn special_contract_call(...) {
    runtime_cost(ContractCall, ...)?;
    let function_name = args[1].match_atom()?;
    let rest_args = evaluate(args[2..])?;

    let (contract, return_constraint) =
        resolve_callable(args[0])?;

    let nested = invoke_ctx.with_caller(
        current_contract.into()
    );

    exec_state.dispatch_contract_call(
        nested, contract, function_name, values
    )
}`}</code></pre>
              </div>
              <ol className="numbered-flow">
                <li><b>Charge</b><span>Meter the contract-call operation; contract loading and function application charge later.</span></li>
                <li><b>Evaluate</b><span>Evaluate arguments in the caller’s engine and convert them to shared kernel <code>Value</code>s.</span></li>
                <li><b>Resolve</b><span>Accept a literal contract principal, contract constant, lexical callable, or trait reference.</span></li>
                <li><b>Rebind authority</b><span>The current contract becomes <code>contract-caller</code>; sender and sponsor are preserved.</span></li>
                <li><b>Dispatch</b><span>Production calls re-enter the host dispatcher so the callee—not the caller—selects the engine.</span></li>
                <li><b>Validate result</b><span>Sanitize the shared value and enforce any dynamic trait return constraint.</span></li>
              </ol>
            </div>
          </div>
        </article>

        <article className={`slide ${current === 5 ? "active" : ""}`} aria-hidden={current !== 5}>
          <div className="slide-inner">
            <Label>Code flow · dispatch</Label>
            <h2>The dispatcher switches engines without switching transactions.</h2>
            <div className="sequence-diagram">
              <div className="sequence-head"><b>Clarity 6 caller</b><b>Kernel ABI</b><b>Stackslib dispatcher</b><b>Selected callee engine</b></div>
              <div className="sequence-row"><span>1</span><p><code>dispatch_contract_call</code></p><i /><p /><p /></div>
              <div className="sequence-row"><span>2</span><p /><p>Build <code>RuntimeContext</code></p><i /><p /></div>
              <div className="sequence-row"><span>3</span><p /><p /><p>Load stored analysis<br /><code>manifest.select(version)</code></p><i /></div>
              <div className="sequence-row"><span>4</span><p /><p><code>take_transaction_context()</code><br />suspend caller slots</p><i /><p /></div>
              <div className="sequence-row emphasis"><span>5</span><p /><p /><p /><p><code>Engine::execute_nested_call</code><br />same DB, costs, frames, stack</p></div>
              <div className="sequence-row"><span>6</span><p>resume evaluator</p><i /><p><code>restore_transaction_context()</code></p><p>return <code>Value</code></p></div>
            </div>
            <div className="file-row"><FileTag>clarity-v6/src/vm/contexts.rs</FileTag><span>→</span><FileTag>clarity-kernel/src/engine.rs</FileTag><span>→</span><FileTag>stackslib/src/clarity_vm/engine.rs</FileTag></div>
          </div>
        </article>

        <article className={`slide ${current === 6 ? "active" : ""}`} aria-hidden={current !== 6}>
          <div className="slide-inner">
            <Label>Gate ownership</Label>
            <h2>Not every epoch-gated change becomes an engine.</h2>
            <div className="gate-table">
              <div className="gate-head"><b>Behavior</b><b>What changed?</b><b>Owner</b><b>Why?</b></div>
              <div><strong><code>map</code> off-by-one</strong><p>evaluator result</p><Label tone="blue">engine revision</Label><p>Only this language algorithm changes.</p></div>
              <div><strong>typed-tuple fields</strong><p>shared deserialization</p><Label tone="green">kernel ruleset</Label><p>Every engine must interpret stored bytes identically.</p></div>
              <div><strong><code>at-block</code></strong><p>surface + epoch-wide shutdown</p><Label tone="red">engine + kernel</Label><p>Recognition is language-owned; historical execution policy is shared.</p></div>
              <div><strong>stacking post-conditions</strong><p>validity + asset framing</p><Label tone="ink">host + kernel</Label><p>The host validates transactions; the kernel records shared movements.</p></div>
            </div>
            <div className="decision-rule"><span>Decision rule</span><p>If a behavior must be identical across every engine in a mixed call graph, it belongs in the kernel. If it changes one language’s evaluation, it belongs in a linkable engine revision.</p></div>
          </div>
        </article>

        <article className={`slide ${current === 7 ? "active" : ""}`} aria-hidden={current !== 7}>
          <div className="slide-inner">
            <Label>Benefits</Label>
            <h2>We spend disk and build time to save reviewer attention.</h2>
            <div className="benefit-cards">
              <section><span>01</span><h3>Smaller blast radius</h3><p>A Clarity 7 edit cannot accidentally alter the frozen Clarity 1–6 implementation.</p><b>SECURITY</b></section>
              <section><span>02</span><h3>Local reasoning</h3><p>One engine revision presents one parser, analyzer, cost profile, and evaluator behavior.</p><b>MAINTAINABILITY</b></section>
              <section><span>03</span><h3>Auditable history</h3><p>Consensus changes become named, linkable revisions selected by an explicit manifest.</p><b>REPRODUCIBILITY</b></section>
              <section><span>04</span><h3>Independent evolution</h3><p>Clarity 7 can simplify or experiment without threading new branches through replay code.</p><b>VELOCITY</b></section>
              <section><span>05</span><h3>Cross-engine safety</h3><p>The ABI forces costs, state, events, assets, and rollback to remain shared.</p><b>COMPOSABILITY</b></section>
              <section><span>06</span><h3>Testable selection</h3><p>Manifest and ruleset mappings are finite tables with exhaustive regression coverage.</p><b>ASSURANCE</b></section>
            </div>
          </div>
        </article>

        <article className={`slide final-slide ${current === 8 ? "active" : ""}`} aria-hidden={current !== 8}>
          <div className="slide-inner final-layout">
            <div>
              <Label tone="green">Where we are</Label>
              <h2>The boundary is implemented—and exercised.</h2>
              <ul className="evidence-list">
                <li><b>14</b><span>Clarity 6 engine/conformance tests passed</span></li>
                <li><b>23</b><span>Clarity kernel tests passed</span></li>
                <li><b>7</b><span>stackslib manifest and mixed-engine tests passed</span></li>
                <li><b>✓</b><span>format, both Clippy suites, no-default build, diff hygiene</span></li>
                <li><b>↻</b><span>full mainnet replay remains the final gate for each consensus batch</span></li>
              </ul>
            </div>
            <div className="next-panel">
              <small>NEXT: CLARITY 7</small>
              <h3>Start behavior-neutral.</h3>
              <p>Clone the proven Clarity 6 semantic point, remove compatibility-shaped internals, and activate it through the manifest.</p>
              <hr />
              <h3>Then change behavior intentionally.</h3>
              <p>Each spec-backed change lands in a new language or engine revision—never as another ambient epoch gate.</p>
            </div>
            <div className="closing-line"><span>Preserve history.</span><span>Isolate semantics.</span><span>Make change reviewable.</span></div>
          </div>
        </article>
      </div>

      <footer className="deck-controls">
        <button onClick={retreat} disabled={current === 0} aria-label="Previous slide">← <span>Previous</span></button>
        <div className="progress" aria-label={`Slide ${current + 1} of ${totalSlides}`}>
          <i style={{ width: `${((current + 1) / totalSlides) * 100}%` }} />
        </div>
        <span className="slide-count"><b>{String(current + 1).padStart(2, "0")}</b> / {totalSlides}</span>
        <button onClick={advance} disabled={current === totalSlides - 1} aria-label="Next slide"><span>Next</span> →</button>
      </footer>

      {overview && (
        <div className="overview" role="dialog" aria-modal="true" aria-label="Slide overview">
          <div className="overview-top"><div><Label tone="green">Deck overview</Label><h2>Jump to a slide</h2></div><button onClick={() => setOverview(false)} aria-label="Close overview">×</button></div>
          <div className="overview-grid">
            {slideTitles.map((title, index) => (
              <button key={title} className={current === index ? "active" : ""} onClick={() => goTo(index)}>
                <span>{String(index + 1).padStart(2, "0")}</span><strong>{title}</strong>
              </button>
            ))}
          </div>
          <p className="overview-hint"><kbd>O</kbd> toggles overview · <kbd>Esc</kbd> closes</p>
        </div>
      )}
    </main>
  );
}
