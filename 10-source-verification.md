# Source Verification Proposal

A deploy publishes a Wasm module on chain. The Clarity source is published off
chain. This document proposes how the source stays public and checkable: what
the module records about its build (the **provenance section**), how a source is
**verified** against a deployed contract, and the **registry** that hosts the
sources. [03-architecture.md](03-architecture.md) sections 2 and 6 name these
and leave them open.

It is kept to what has to be agreed. The provenance section is on chain and
permanent, so its contents are fixed here. Everything off chain is described as
the least that works, and the details are left to whoever builds it.

One thing is new for Stacks. Legacy contracts are deployed as source, so every
contract is readable. On the new chain a deployer can choose not to publish, and
nothing on chain can prevent that. Such a contract is shown as unverified
(section 7).

## 1. Prior art

| System                                                                                                                                          | Where the source is               | How it is verified                                                                               |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------ |
| Legacy Clarity                                                                                                                                  | on chain                          | nothing to verify: the node interprets the source                                                |
| Etherscan                                                                                                                                       | Etherscan's database              | the submitter states the compiler and settings; Etherscan recompiles and compares                |
| [Solidity metadata](https://docs.soliditylang.org/en/latest/metadata.html) and [Sourcify](https://docs.sourcify.dev/docs/exact-match-vs-match/) | IPFS and Sourcify's open database | the bytecode ends in a hash that covers the sources and settings; anyone recompiles and compares |
| [Solana verified builds](https://solana.com/docs/programs/verified-builds)                                                                      | a git host                        | a git URL and commit are recorded on chain; rebuild in a pinned Docker image                     |
| [NEAR NEP-330](https://github.com/near/NEPs/blob/master/neps/nep-0330.md)                                                                       | a git host or IPFS                | the contract returns a source link and a Docker image; rebuild in that image                     |
| [Stellar SEP-55](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0055.md)                                                 | GitHub                            | no rebuild: a GitHub Actions attestation for the Wasm hash is looked up                          |
| [Arbitrum Stylus](https://github.com/OffchainLabs/cargo-stylus)                                                                                 | wherever the deployer puts it     | the Wasm carries a hash of the project's sources; rebuild in Docker                              |

What this design takes from them:

- **The deployed module commits to its source by hash**, not by URL. Anyone
  holding the source can then publish it, and a moved or deleted repository
  breaks nothing.
- **Verification is a rebuild**, not an attestation, and it needs no Docker
  image because the compiler is deterministic on every platform.
- **One result.** A source reproduces the module or it does not.
- **Open data**, and every compiler release stays runnable.

The design is closest to Solidity metadata with Sourcify, without the metadata
file (the provenance section is on chain) and without compiler settings (the
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

1. **The chain is the trust anchor.** The module on chain names its source by
   hash, and the deployer signed the deploy transaction.
2. **The rebuild is the proof.** Compilation is deterministic
   ([03-architecture.md](03-architecture.md) section 2), so whether a source
   reproduces a module is a fact anyone can recompute.
3. **The registry is trusted only for availability.** It cannot serve a wrong
   source or make a false verdict stick. It can only lose a source.

## 3. The provenance section

`abi.provenance` is a custom section of the module
([07-chain-abi.md](07-chain-abi.md) section 3.4). The chain checks only its
size. It records:

| Field              | Holds                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `language`         | `clarity`                                                                                                            |
| `format`           | the version of this layout, `1`                                                                                      |
| `language-version` | the number in the source's `clarity-version` declaration                                                             |
| `compiler`         | the compiler's name and its exact release                                                                            |
| `contract`         | the principal of the contract the module is built for, deployer and name                                             |
| `source-hash`      | `sha512/256` of the source text                                                                                      |
| `callees`          | for each contract whose sections the build read: its principal and the hashes of its `abi.interface` and `abi.types` |

- **`language` and `format` come first.** The chain is shared by every source
  language and a deployed section is never rewritten, so a reader must be able
  to tell which layout it is looking at.
- **The source hash is over the exact bytes of the source**, comments and
  whitespace included. The grammar rejects carriage returns and non-ASCII
  characters ([spec/05-grammar.md](spec/05-grammar.md)), so one text has one
  byte string on every platform.
- **`contract` is the principal the module is deployed at.** A module is built
  for one contract, so the same source deployed at two addresses gives two
  modules. The chain does not check the field. A module deployed anywhere else
  cannot be verified.
- **The section has one encoding for given build inputs**, so a rebuild
  reproduces it with the rest of the module. The byte layout is fixed when the
  compiler implements it.

It records nothing else:

- **No compiler options.** There are none that change the output.
- **No URL, repository, or commit.** A location is not a commitment.
- **No author, license, or audit link.** The rebuild cannot check them. They can
  be added in the registry later (section 9).

Because the module names its contract, `contract-hash?`, which hashes the whole
module, is different for every contract. Recognising a known template on chain
is a separate feature from source verification, and it needs a hash that leaves
the provenance section out (section 11).

A provenance section proves nothing by itself: anyone can write a module by hand
and name a well-known source in it. Only the rebuild ties the two together, so
no tool shows a source on the strength of a matching hash alone.

## 4. Verification

`clarity-verify` takes a contract and a source, and answers whether the source
is that contract's:

1. Read the provenance section of the module on chain.
2. Check that it names this contract, and that the hash of the source is the
   one recorded.
3. Run the named compiler release on the source, the contract's principal, and
   the callees' sections (read from the chain and checked against the recorded
   hashes).
4. Compare the output with the module.

The contract is **verified** if the two are equal byte for byte. Otherwise the
answer is a failure with its reason. There is no partial result. Before a
deploy, the same check runs on a module file, which names the contract it is
built for.

Verification establishes that the module is what that compiler release produces
from that source. It does not establish that the compiler is correct, which is
the job of the conformance suite ([03-architecture.md](03-architecture.md)
section 6). When a release turns out to have a bug, every contract built with it
names that release on chain.

## 5. The source registry

The registry stores the sources of verified contracts and serves them. It is a
backend only. Explorers, wallets, and the Stacks API display what it holds.

It does three things:

- **Publish.** Anyone sends a source for a contract, and the registry verifies
  it (section 4). If the contract is verified it stores the source, and if not
  it answers with the reason and stores nothing.
- **Read.** For a contract, whether it is verified, and its source.
- **List.** The records it holds, in the order it stored them, starting after
  any given point. Read from the start, the list is a full copy of the registry.

The rules that keep it simple:

- **No account and no authentication.** Holding the source is the only
  credential. The deployer, an auditor, or any user with a copy can publish, at
  deploy or years later.
- **It stores only what it has verified.** Every source it holds reproduces a
  deployed module, which someone paid to deploy. That is the spam defense.
- **It does not follow the chain.** A source is published per contract, in one
  request.
- **Clarinet publishes when a deploy confirms**, by default.

It is an availability service, not an authority. A source it serves is checked
against the hash on chain, and anyone can rerun its verdict with
`clarity-verify`. Wallets and explorers take its answer as it is for
convenience, not because they have to.

**Stacks Labs runs a registry, and launch needs no other.** The risk in a single
registry is a lost source. It is backed up, the list lets anyone keep a full
copy, and whoever has a source can publish it again.

**Anyone can run another one.** No permission is needed, because a registry is
not trusted: what it serves is checked against the chain. Nothing on chain
refers to a registry either. A new operator runs the same service and gives it
the address of a registry to copy. It reads that registry's list from the start,
then asks for new records about once a minute. It verifies each source before
storing it, so no registry has to trust another.

- **The registry being copied does nothing**, and need not know.
- **Two registries can copy each other.** Nothing can conflict, because a
  contract's module names exactly one source.
- **An operator chooses which registries to copy.** Each record costs a
  compilation, so this is a setting, not open to anyone.
- **Optionally, a registry asks the ones it copies** about a contract it does
  not have yet, before answering that it is unverified.

Three things keep this possible from launch:

- The registry is open source and documented for self-hosting.
- Its API is documented, so registries are interchangeable.
- Clarinet, the Stacks API, and explorers take the registry's address as a
  setting.

Only the list has to exist at launch. The copying side can follow, since the
first registry has nothing to copy.

## 6. Compiler releases

Verifying a contract needs the compiler release its provenance names, for as
long as the contract exists.

- **A release is immutable.** A fix is a new version.
- **Every release is kept and stays runnable**, on any platform and on a source
  from anyone. Shipping each release as a Wasm build of the compiler as well is
  the suggested way.

## 7. What users see

- A contract is **verified** or **unverified**, and wallets and explorers show
  which.
- Source is shown only for a verified contract. So is anything derived from it,
  such as cost bounds and analyses.
- A wallet warns before a transaction that calls an unverified contract.
- Legacy contracts are unaffected. Their source is on chain.

## 8. Implementation

Only the outline is given here. The HTTP API, the schema, limits, reorg
handling, and how compiler releases are run are the implementer's to decide.

- **`clarity-verify`** is a Rust library with a thin command-line tool. The
  registry and Clarinet both use the library.
- **The registry** is one standalone, open-source Rust service: axum for HTTP,
  SQLite for the records and the sources, and a node's RPC to read modules. A
  source is verified while its publisher waits, so there is no queue. The only
  background work is copying another registry, when one is set.
- **Clarinet** publishes the source when a deploy confirms, and has a
  `clarinet verify` command.
- **The Stacks API** asks the registry and adds a contract's verified status and
  source to what it already returns, so explorers and wallets need no new
  dependency.

The order of work is `clarity-verify`, then the registry, then Clarinet and the
API.

## 9. Not in the first version

- Following the chain, to verify a new deploy of a source already held.
- A way for tools to discover registries.
- Keeping failed verifications, to warn about a contract with false provenance.
- Cost bounds and proofs, published next to the source.
- Annotations signed by the deployer: project name, license, repository, audits.
- A list of known compiler bugs by release.
- Verification in the wallet or the browser.
- Serving legacy contracts' sources from the same service.

All of these can be added later, and they then apply to contracts already
deployed. Each is computed from a contract's module and its source, or is
something the registry does, so none needs a change to the provenance section.

Three things have to be right from the first deploy for that to hold: the
contents of the provenance section, every compiler release being kept, and
sources not being lost.

## 10. Changes to the earlier documents

Adopting this proposal changes the following. None of the changes is made yet.

1. **Provenance starts with `language` and `format`**, in
   [07-chain-abi.md](07-chain-abi.md) section 3.4.
2. **The compiler has no options that change its output**, a rule to add to
   [03-architecture.md](03-architecture.md) section 2.
3. **The contract's principal is a build input, and provenance records it.**
   [03-architecture.md](03-architecture.md) section 2 names the deploying
   principal only, and does not list it in the provenance section.
4. **Compiler releases are kept and stay runnable**, an addition to
   [05-roadmap.md](05-roadmap.md) Phase 4.

## 11. Open questions

The first three are on chain, so they are to be settled before launch.

1. **The source hash function.** `sha512/256` is what the ABI uses everywhere
   else. `sha256` would let the on-chain hash double as an IPFS content
   identifier. This proposal keeps one hash function.
2. **`contract-hash?`** ([spec/03-primitives.md](spec/03-primitives.md) 3.5).
   It hashes the whole module, which now differs for every contract. For a
   contract to recognise a known template on chain, it has to hash the module
   without the provenance section, or another primitive has to. That value
   depends on the compiler release, so a template has one hash per release. It
   cannot be the recorded source hash instead: the chain does not check that a
   module was built from the source it names, so a hand-written module could
   name an audited source and pass for it on chain.
3. **Per-definition hashes** ([spec/03-primitives.md](spec/03-primitives.md)
   open question 3). If only tools need them, they are computed from verified
   source at any time. If a contract must read another contract's on chain, they
   go in the provenance section, and contracts deployed before that never have
   them.
4. **Sections of legacy callees.** A vNEXT contract that calls a legacy one
   builds against sections the chain derives from the legacy contract
   ([03-architecture.md](03-architecture.md) section 7). A verifier must be able
   to read the same sections from a node. This is the chain team's to confirm.
5. **Wallet policy.** Whether a wallet only warns on an unverified contract or
   requires an explicit override.
