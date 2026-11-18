# Source Verification Proposal

A deploy publishes three things on chain, all inside the module: the Wasm code,
the interface and declared types (`abi.interface`, `abi.types`), and the
provenance section. The Clarity source is published off chain. This document
specifies the two pieces that [03-architecture.md](03-architecture.md) sections
2 and 6 name but leave open: the **contents of the provenance section** and the
**source registry**, with the verification procedure that connects them.

Like [07-chain-abi.md](07-chain-abi.md), it takes a position on every question.
One principle decides how much it specifies. The provenance section is on chain
and can never be changed for a deployed contract, so it is specified completely.
The registry is off chain and can grow, so it is specified as the least that
works, and what was left out is listed in section 9. References of the form
"chain ABI 3.4" are to sections of [07-chain-abi.md](07-chain-abi.md).

One consequence should be stated first, because it is new for Stacks. Legacy
contracts are deployed as source, so every contract is readable by construction.
On the new chain a deployer can choose not to publish. Nothing on chain can
prevent that; the design's answer is that an unpublished contract is visibly
unverified everywhere it is shown (section 7).

## 1. Prior art

| System                                                                                                                                          | What the chain holds                                                                                                                 | Where the source is               | How it is verified                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Legacy Clarity                                                                                                                                  | the source itself                                                                                                                    | on chain                          | nothing to verify: the node interprets the source                                                     |
| Etherscan                                                                                                                                       | bytecode only                                                                                                                        | Etherscan's database              | the submitter states compiler, settings, and constructor arguments; Etherscan recompiles and compares |
| [Solidity metadata](https://docs.soliditylang.org/en/latest/metadata.html) and [Sourcify](https://docs.sourcify.dev/docs/exact-match-vs-match/) | bytecode ending in the hash of a metadata file; the file names the compiler, its settings, and the hash of every source file         | IPFS and Sourcify's open database | anyone submits; recompile and compare. "Exact match" includes the metadata hash, "match" ignores it   |
| [Solana verified builds](https://solana.com/docs/programs/verified-builds)                                                                      | the program, and a separate account written by the uploader with a git URL, commit, and build arguments                              | a git host                        | rebuild in a pinned Docker image, locally or by a remote verifier whose answer the explorer shows     |
| [NEAR NEP-330](https://github.com/near/NEPs/blob/master/neps/nep-0330.md)                                                                       | a view function returning a source link, a source snapshot (git commit or IPFS), a digest-pinned Docker image, and the build command | a git host or IPFS                | rebuild in that image and compare                                                                     |
| [Stellar SEP-55](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0055.md)                                                 | a `source_repo` entry in the Wasm's `contractmetav0` custom section                                                                  | GitHub                            | no rebuild: a GitHub Actions attestation for the Wasm hash is looked up                               |
| [Arbitrum Stylus](https://github.com/OffchainLabs/cargo-stylus)                                                                                 | Wasm with a `project_hash` custom section, a hash over the project's source files                                                    | wherever the deployer puts it     | rebuild in Docker and compare with the deployment transaction                                         |

### Lessons

- **L1. Commit to the source inside the deployed artifact.** Solidity's metadata
  hash and Stylus's project hash make the deployer's signature cover the source.
  Anyone holding the source can then publish it, with no account and no proof of
  being the deployer. Etherscan, with no commitment, accepts any source that
  compiles to the same code, including one with misleading comments and names.
- **L2. Commit to content, not to a location.** A git URL (Solana, NEAR,
  Stellar) breaks when a repository moves, goes private, or is deleted, and it
  makes a hosting company part of the trust path.
- **L3. One tier.** Sourcify renamed "partial match" because users read it as
  "not verified". A source either reproduces the module or it does not.
- **L4. Reproducibility belongs to the compiler, not to a container.** Every
  Rust-based chain pins a Docker image because the toolchain's output depends on
  its environment. An image is a large, opaque, perishable build input.
- **L5. Record every build input.** Verification on Etherscan commonly fails on
  a wrong optimizer setting, library address, or constructor argument: inputs
  the bytecode does not name and the submitter must guess.
- **L6. Verify by rebuilding, not by attestation.** SEP-55 trusts GitHub's
  build runner; a remote verifier's answer is trusted by whoever does not
  rebuild. An attestation is only as good as its signer, forever.
- **L7. Open data.** Etherscan's closed database is why Sourcify exists.
- **L8. Every compiler release stays runnable forever.** A contract deployed
  today is verified again in ten years, with the compiler of today.

The design below is closest to Solidity metadata with Sourcify, minus the two
things that complicate it: a metadata file between the bytecode and the source
(the provenance section is the metadata, on chain), and compiler settings (the
Clarity compiler has none that change its output).

## 2. Overview

```
 developer                       chain                        registry
 ─────────                       ─────                        ────────
 build: source ─► module
 deploy transaction (module) ──► validate, store module
 publish source for the contract ──────────────────────────► read the module from the chain,
                                                              rebuild from the source, compare;
                                                              if equal, store the source
 wallet, explorer ◄── module ───
                  ◄── verified? source ──────────────────────
```

Three facts carry the design:

1. **The chain is the trust anchor.** The module on chain names its source by
   hash. The deploy transaction is signed, so the deployer has signed that hash.
2. **The rebuild is the proof.** Compilation is deterministic on every platform
   ([03-architecture.md](03-architecture.md) section 2), so whether a source
   reproduces a module is a fact anyone can recompute.
3. **The registry is therefore trusted for nothing but availability.** It cannot
   serve a wrong source (the hash would not match) and cannot make a false
   verdict stick (anyone can recompute it). What it can do is lose the source.

## 3. The provenance section

### 3.1 Contents

`abi.provenance` is a custom section of the module (chain ABI 3.4). The chain
checks only its size. Its bytes are, in order:

| Field              | Encoding                                                                                                                                                                            |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `language`         | string; `clarity` for this layout                                                                                                                                                   |
| `format`           | u32 BE, the version of this layout: `1`                                                                                                                                             |
| `language-version` | u32 BE, the number in the source's `clarity-version` declaration (spec 2.4.0)                                                                                                       |
| `compiler`         | string, the compiler's identifier; `clarity` for the reference compiler                                                                                                             |
| `compiler-version` | string, the exact release, `MAJOR.MINOR.PATCH`                                                                                                                                      |
| `source-hash`      | 32 bytes, `sha512/256` of the source                                                                                                                                                |
| `callees`          | u32 BE count, then per callee: its contract principal (chain ABI 2.2), the 32-byte hash of its `abi.interface`, one byte `0` or `1`, and if `1` the 32-byte hash of its `abi.types` |

A string is a u8 length and that many bytes of printable ASCII. No bytes may
follow `callees`.

Rules:

- **`language` and `format` come first.** The chain is shared by every source
  language, and a deployed section can never be rewritten, so a reader must be
  able to tell which layout it is looking at. The fields after these two are
  Clarity's.
- **The source hash is over the exact bytes of the source text**, with no
  normalization. The grammar already rejects a carriage return and any non-ASCII
  character ([spec/05-grammar.md](spec/05-grammar.md)), so one text has one byte
  string on every platform. Comments and whitespace are covered: the published
  source is the text the deployer built from, to the byte (L1).
- **A source is one text.** A contract has one source, the prelude belongs to
  the compiler release, and there are no imports, so there is no file name, no
  path, and no manifest to record.
- **`compiler-version` names one release** (section 6). A development build
  writes a version with a pre-release suffix, and a module it produced cannot be
  verified.
- **`callees` lists every contract whose sections the build read**
  ([03-architecture.md](03-architecture.md) section 2), sorted in strictly
  ascending byte order of principal, each once. The `abi.types` hash is absent
  when the callee has no such section.
- **The section has exactly one encoding for given build inputs** (chain ABI
  R2). The compiler writes it, and a rebuild reproduces it along with the rest
  of the module.

The section costs about 100 bytes, plus about 100 per callee. The source it
replaces on chain is typically several kilobytes.

### 3.2 What is deliberately absent

| Not recorded                              | Why                                                                                                                                                                                                                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Compiler options                          | There are none. A compiler has one output per set of build inputs; anything that would change the output is a different release (L5)                                                                                                                                     |
| A URL, repository, or commit              | A location is not a commitment (L2). It would also be a build input, so the same source published from two places would give two modules                                                                                                                                 |
| A build environment                       | The compiler is deterministic across platforms, so the release is the environment (L4)                                                                                                                                                                                   |
| The deployer                              | It is on chain already, as the address part of the contract's principal, and a verifier reads it there (4.1). Recording it would make every module specific to its deployer, so the same source would have a different `contract-hash?` for each account that deploys it |
| Author, license, project name, audit link | Unverifiable claims. They do not belong in a section whose value is that every field is checked by the rebuild                                                                                                                                                           |

### 3.3 Consequences

- **A module is specific to its deployer only if its source is.** A source with
  no deployer-relative `.name` reference compiles to the same bytes, and the
  same `contract-hash?`, whoever deploys it. One with such a reference differs
  by deployer, because the resolved principals are compiled in.
- **`contract-hash?` identifies the source text, not only the code.** Changing a
  comment changes the source hash and so the module. A contract that compares
  another's hash with a known value accepts exactly one text.
- **A provenance section proves nothing by itself.** Anyone can write a module
  by hand and give it a section naming a well-known source. Only the rebuild
  ties the two together, which is why no tool may show a source for a module on
  the strength of a matching hash alone.

## 4. Verification

### 4.1 Procedure

`clarity-verify` takes a contract and a source, and answers whether the source
is that contract's. It reads the module from the chain and takes the deployer
from the contract's principal. Before deploy, it takes a module file and the
principal that will deploy it.

1. Read the module's `abi.provenance`.
2. Find the compiler release it names (section 6).
3. Check that the source's `sha512/256` is the recorded `source-hash`.
4. For each callee, read the module deployed at that principal and check the
   hashes of its `abi.interface` and `abi.types` against the recorded ones.
5. Run that compiler release on the source, the contract's deployer, and those
   sections, and compare the output with the module.

The contract is **verified** if the output of step 5 equals the module byte for
byte, provenance included. There is no partial result (L3). Any other outcome is
a failure with a reason:

| Step | Reason                           | Typical cause                                                                                |
| ---- | -------------------------------- | -------------------------------------------------------------------------------------------- |
| 1    | no readable provenance           | another language, hand-written Wasm                                                          |
| 2    | unknown compiler release         | a development build                                                                          |
| 3    | not this contract's source       | the wrong file, or a file edited since the build                                             |
| 4    | a callee differs                 | the source was compiled against a contract other than the one deployed at that principal     |
| 5    | the source does not reproduce it | forged provenance; a module built for another deployer; a compiler that is not deterministic |

On the second cause in the last row: because step 5 uses the contract's own
deployer, a module built for one deployer and deployed by another fails whenever
its source has a `.name` reference. That is the right answer, since the module's
references point at the first deployer's contracts, which is not what the source
says at the second address.

### 4.2 What verification does and does not establish

It establishes that the module is what that compiler release produces from that
source. It does not establish that the compiler is correct: a miscompiled
contract verifies. That is the job of the conformance suite and differential
testing ([03-architecture.md](03-architecture.md) section 6). Provenance does
make the damage findable: when a release turns out to have a bug, every contract
built with it names that release on chain.

## 5. The source registry

### 5.1 Role

The registry stores the sources of verified contracts and serves them. It is a
backend only: it has no user interface, and what it holds is displayed by its
clients. Those are explorers, wallets, and the Stacks API, which can relay a
record to the tools that already use it (8.3). What they display is section 7.

It is an availability service, not an authority:

| Threat                                            | Outcome                                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------------------------- |
| The registry serves a different source            | The reader hashes what it receives; the hash is not the one in the module             |
| The registry says a contract is verified, falsely | Anyone can rerun section 4.1 with `clarity-verify` and the source the registry serves |
| A module claims a source it was not built from    | The rebuild differs, and the registry stores nothing                                  |
| A deployer does not publish                       | The registry has nothing for the contract, which is shown as unverified (section 7)   |
| The registry loses a source                       | The contract is unverified until someone who kept the source publishes it again (5.4) |

Wallets and explorers take the registry's answer as it is. That is a choice of
convenience, not a requirement of the design: nothing the registry says has to
be taken on trust.

### 5.2 Protocol

| Request                                            | Response                                                                                                                            |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `POST /v1/contracts/{principal}`, body: the source | Runs section 4.1. If the contract is verified, stores the source and the record. If not, answers with the reason and stores nothing |
| `GET /v1/contracts/{principal}`                    | The record, or not found                                                                                                            |
| `GET /v1/sources/{source-hash}`                    | The source text                                                                                                                     |
| `GET /v1/dump`                                     | An archive of every record and source (5.4)                                                                                         |

A hash is 64 lowercase hex digits. A principal carries its network in its
version byte, so mainnet and testnet share one namespace. A record:

```json
{
  "contract": "SP3FB…amm-pool",
  "module": "9f2c…",
  "source": "51d0…",
  "compiler": "clarity",
  "compiler-version": "1.4.2"
}
```

A record exists only for a verified contract, so it has no status field.
`module` is the hash `contract-hash?` returns, so a reader can check that the
record describes the module now on chain.

### 5.3 Publishing

- **No account and no authentication.** Holding the source is the only
  credential. The deployer, an auditor, or a user with a copy can publish, at
  deploy or years later.
- **The registry stores only what it has verified.** Every source it holds
  reproduces a deployed module, and each of those was paid for by a deploy. That
  is the whole of the spam defense.
- **Publishing is per contract.** The registry does not follow the chain. When
  the same source is deployed again at another address, it is published again
  for that contract, which costs one request.
- **Clarinet publishes when a deploy confirms**, by default. Opting out is a
  flag, and the deployer who uses it ships an unverified contract.

### 5.4 One registry

Stacks Labs runs the registry, and at launch it is the only one. The risk in
that is the last row of 5.1: a lost source. Three things stand against it:

- **The deployer has the source** and can publish it again, as can anyone else
  who kept a copy.
- **The registry is backed up.**
- **The registry publishes a dump** of everything it holds, refreshed daily.
  Anyone can keep a copy. Nothing in the registry is private and there is no API
  key (L7).

### 5.5 A second registry, later

Nothing above assumes a single registry, and nothing on chain refers to one. A
second operator would:

1. Start from a dump, and verify each contract in it itself instead of copying
   the verdicts. A verdict costs one compilation, and recomputing it is what
   makes two registries independent.
2. Stay current by asking the first registry for any contract it is asked about
   and does not have, and by reading a feed of new records, which the first
   registry would add at that point.

Tools would then take a list of registries instead of one address. None of this
is built for launch.

### 5.6 Alternatives not taken

| Alternative                                                              | Why not                                                                                                                                                    |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source in the deploy transaction, stored by nodes but not executed       | This is the status quo's cost with a different label: every node carries every source forever, and the chain is again aware of Clarity source              |
| Nodes replicate sources among themselves, as Atlas did for BNS zonefiles | The strongest availability, but it puts a second, non-consensus data network in every node. Kept as the fallback if a registry proves fragile (section 11) |
| A git URL and commit in the module (Solana, NEAR, Stellar)               | L2                                                                                                                                                         |
| A build attestation instead of a rebuild (SEP-55)                        | L6. It also needs a trusted builder, which a deterministic compiler makes unnecessary                                                                      |
| IPFS as the registry                                                     | Content stays on IPFS only while someone pins it, so it relocates the availability problem without solving it                                              |

## 6. Compiler releases

Verifying a contract needs the compiler release its provenance names, for as
long as the contract exists (L8).

- **A release is immutable.** A version is never rebuilt or replaced. A fix is a
  new version.
- **Every release includes a Wasm build of the compiler** that reads its build
  inputs and writes a module, with no access to a clock, a file system, or the
  network. This is what a verifier runs. One artifact per release then works on
  every platform and keeps working, and a verifier can run it on a source from
  anyone without trusting that source.
- **The compiler project publishes the releases**, and the registry keeps a copy
  of each.

## 7. What users see

- A contract is **verified** or **unverified**. Wallets and explorers show
  which.
- Source is shown only for a verified contract. So are cost bounds, analyses,
  and proofs, which are stated for a verified triple
  ([03-architecture.md](03-architecture.md) section 6).
- A wallet warns before a transaction that calls an unverified contract. The
  call still has the chain's runtime guarantees
  ([03-architecture.md](03-architecture.md) section 5), but none of Clarity's.
- An unverified contract's interface and declared types remain readable, since
  they are on chain, but they are its author's claim
  ([08-value-interpretation.md](08-value-interpretation.md) section 5.3).
- Legacy contracts are unaffected. Their source is on chain and tools read it
  there.

## 8. A possible implementation

This section sketches the registry Stacks Labs would run. It is illustrative:
names are placeholders, and the protocol is section 5.2, whatever is behind it.

### 8.1 Shape

One standalone service with one database. It is not part of the Stacks API,
which is one of its clients (8.3).

```
 POST source ──► read the module and its callees' from a node
                 ──► run the named compiler release ──► compare
                 ──► store the source and the record
 GET ──────────► read from the database
```

There is no chain follower, no queue, and no background work except a daily
dump. A request to publish is verified while the publisher waits.

### 8.2 Stack

| Concern            | Choice                 | Why                                                                                                                                                            |
| ------------------ | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Rust                   | `clarity-verify` and the module parser are Rust crates and are linked, not bridged; the service ships as one binary                                            |
| HTTP               | axum                   | Three GETs and one POST; tower middleware covers rate limits, body limits, and timeouts                                                                        |
| Compiler execution | wasmtime               | Every past release must run, on source anyone can post. Releases are Wasm (section 6), and wasmtime bounds each run's memory and time                          |
| Storage            | SQLite, through `sqlx` | Records and sources in one file. A source is a few kilobytes and there is one writer. `sqlx` keeps Postgres open if the service ever runs as several instances |
| Chain access       | a node's RPC           | The registry needs only module bytes, for the contract and its callees                                                                                         |

The database holds the only copy of each source that Stacks Labs controls, so it
is what gets backed up, and the daily dump (5.4) is an export of it. The crates
are named from general knowledge, and their current state is to be checked when
the project is scaffolded.

### 8.3 Around the registry

- **`clarity-verify`** is a library crate with a thin command-line tool on top.
  The registry and Clarinet link the crate. The tool is usable without either:
  given a contract, a node, and a local source file, it runs section 4.1.
  - The core of the crate does no I/O. It takes the module, the source, the
    deployer, and the callees' sections, runs a compiler, and compares. The
    caller supplies the chain data, from a node or from Clarinet's simnet or
    devnet, and the compiler.
  - Running an archived compiler release needs wasmtime, which is an optional
    feature of the crate. The registry and the tool enable it. Clarinet can
    leave it off for as long as it only verifies modules built by the release
    it links.
- **Clarinet** uses the crate at three points:
  - before a deploy, to check that the module it is about to broadcast rebuilds
    from the source (the pre-deploy form of 4.1);
  - when the deploy confirms, to verify the contract on chain and publish the
    source (5.3);
  - on demand, as a `clarinet verify` command for any deployed contract and a
    local source file.
- **The Stacks API** adds whether a contract is verified, and a link to its
  source, to what it returns for a contract, by asking the registry. Explorers
  and wallets that already use the API need no new dependency.

### 8.4 Details to settle when building

- **Reorgs.** A deploy can be orphaned, and a different module could later
  appear at the same principal. The registry verifies only deploys past a
  confirmation depth, and a reader can compare the record's `module` with the
  chain.
- **Limits.** The source size limit follows the module size limit (chain ABI
  9.3). The memory and time bounds on a rebuild are set far above what a
  deployable contract needs.
- **Order of work.** `clarity-verify` first, since it is useful alone and
  everything else calls it. Then the registry. Then Clarinet and the API.

## 9. Not in the first version

Each of these was considered and left out:

| Left out                                                                     | Where it would live                                                          |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Following the chain, to verify a contract whose source is already held       | the registry's behavior; no new data                                         |
| A second registry and the feed it would read (5.5)                           | the registry's behavior; no new data                                         |
| Storing failed verifications, to warn about a contract with false provenance | the registry, with the contract's record                                     |
| Cost bounds and proofs, published next to the source                         | the registry, with the contract's record                                     |
| Annotations: project name, license, repository, audit reports                | the registry, as statements signed by the deployer's key                     |
| A list of known compiler bugs by release, as Solidity keeps                  | the compiler project; the registry matches it against `compiler-version`     |
| Verification in the wallet or the browser                                    | the user's device, running the release's Wasm build on the registry's source |
| Serving legacy contracts' sources through the same protocol                  | the registry                                                                 |

### 9.1 They apply to contracts already deployed

None of these needs a change to the provenance section. Each is computed from a
contract's module and its source, or is something the registry does. The module
is on chain for good and names its compiler release and its source, so whenever
one of these is added, the registry can produce it for every vNEXT contract ever
deployed, not only for new ones.

None of them belongs in the provenance section either. The section is fixed at
deploy, while a license, a repository, or an audit changes afterwards. Every
field of it is part of the module, so two deploys of one source under different
project names would stop being the same module. And its value is that the
rebuild checks every field, which it could not do for a name.

### 9.2 What has to be right from the first deploy

That promise holds only if four things are right from the start:

1. **The provenance layout**, including the hash function (section 11).
2. **Every compiler release includes its Wasm build and is kept** (section 6). A
   contract whose release is lost can never be verified again.
3. **Sources are not lost** (5.4). Everything derived needs the source. For a
   contract whose source was never published, only a signed annotation is
   possible.
4. **Anything on-chain code must read is in the module.** A contract sees only
   what is in another contract's module. Tools can derive data later; contracts
   cannot. Per-definition hashes are the one known case (section 11).

### 9.3 How durable this data is

It is as durable as the registry, with one difference worth knowing. A cost
bound, a proof, or a failed verification can be recomputed by anyone from the
module and the source, so losing it costs a computation. An annotation cannot:
if it were lost, the deployer would have to sign it and submit it again.

## 10. Changes to the earlier documents

Adopting this proposal changes the following. None of the changes is made yet.

1. **Provenance starts with `language` and `format`.** Chain ABI 3.4 says the
   section's contents are owned by the toolchain. That stays true of everything
   after those two fields.
2. **The compiler has no options that change its output**, a rule to add to
   [03-architecture.md](03-architecture.md) section 2.
3. **Compiler releases include a Wasm build**, an addition to
   [05-roadmap.md](05-roadmap.md) Phase 4.

## 11. Open questions

1. **The source hash function.** `sha512/256` is what the ABI uses everywhere
   else. `sha256` would make the on-chain hash usable as an IPFS content
   identifier, so that a source could be fetched from IPFS with no registry.
   This proposal keeps one hash function. The choice is on chain, so it has to
   be settled before launch.
2. **Sections of legacy callees.** A vNEXT contract that calls a legacy one
   records the hashes of sections the chain derives from the legacy contract's
   analysis ([03-architecture.md](03-architecture.md) section 7). That mapping
   must be deterministic, frozen, and served by nodes, or those hashes cannot be
   checked. This is the chain team's to confirm.
3. **Copies outside Stacks Labs.** When a second registry (5.5) is needed, who
   runs it, and whether nodes should carry sources instead (5.6).
4. **Wallet policy.** Whether a wallet only warns on an unverified contract or
   requires an explicit override.
5. **Per-definition hashes** ([spec/03-primitives.md](spec/03-primitives.md)
   open question 3). If only tools need them, they are computed from verified
   source at any time, for every contract. If a contract must be able to check
   another contract's definitions on chain, they go in the provenance section,
   and contracts deployed before that never have them (9.2). So this is to be
   decided before launch.
