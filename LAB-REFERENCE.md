# AutoShift lab — verified reference briefing

Authoritative source material for the lab in this repository. Every technical claim below was
read out of the `autoshiftv2` repository, not recalled. **Do not state an AutoShift fact that is
not in this file or in one of the linked source files.** If something is needed and is not here,
stop and ask rather than inferring it.

Verified against `autoshiftv2` branch `feature/autoshift-ui`, 2026-08-12.

## Source files

Read these directly; they are the primary references:

- `docs/quickstart.md`, `docs/developer-guide.md`, `docs/values-reference.md`
- `docs/gradual-rollout.md`, `docs/hub-of-hubs.md`, `docs/cluster-set-assignment.md`
- `docs/releases.md`, `docs/cluster-install.md`
- `autoshift/values/global.yaml`
- `autoshift/values/clustersets/hub-minimal.yaml`, `hub.yaml`
- `autoshift/values/clustersets/_example.yaml` (the full label catalog)

Where `docs/values-reference.md` disagrees with the values files about a channel or version, **the
values files win**. The docs drift.

## What AutoShift is

An Infrastructure-as-Code framework for configuring OpenShift clusters at scale using Red Hat
Advanced Cluster Management and OpenShift GitOps. It deploys ACM policies as individual charts to
run Day 2 configuration across a hub and its managed clusters.

## Current verified versions

Do not hardcode these in prose. They belong in `_attributes.adoc` and are quoted here so the lab's
commands are correct.

| Thing | Value | Source |
|---|---|---|
| OpenShift | `4.22.8` | `hub-minimal.yaml` `openshift-version` |
| ACM channel | `release-2.17` | `hub-minimal.yaml` `acm-channel` |
| GitOps channel | `gitops-1.21` | `hub-minimal.yaml` `gitops-channel` |
| Pipelines channel | `pipelines-1.23` | `hub.yaml` |
| Quay channel | `stable-3.18` | `hub.yaml` |
| NFD channel | `stable` | `hub.yaml` |
| Go (module 6 only) | `1.25.12` | `tools/go.mod` |

The repository is **`https://github.com/auto-shift/autoshiftv2`**. Do not write any other
organisation name. The Go module path is `github.com/auto-shift/autoshiftv2/tools`.

## Architecture the lab teaches

### PolicyGenerator, not Helm

Nearly every policy under `policies/` is a **PolicyGenerator** directory:
`policy-generator-config.yaml` + `kustomization.yaml` + `manifests/` + `placement-*.yaml`,
rendered into ACM `Policy` objects by the PolicyGenerator CMP sidecar in the Argo CD repo-server.

Exactly **four Helm holdouts** remain, because they bootstrap the machinery itself:

- `policies/stable/openshift-gitops/`
- `policies/stable/policy-foundation/`
- `policies/stable/cluster-labels/`
- `policies/stable/cluster-config-maps/`

`helm template policies/stable/<name>/` **does not work on a PolicyGenerator directory**, even
though `docs/developer-guide.md` still shows it in its Quick Start. The canonical local render is:

```
make install-policy-generator
KUSTOMIZE_PLUGIN_HOME=$PWD/.tools/kustomize-plugin .tools/kustomize build \
  --enable-alpha-plugins --enable-helm --load-restrictor LoadRestrictionsNone \
  policies/stable/my-component/
```

`scripts/generate-policy.sh` refuses to operate on a directory containing `Chart.yaml`
(`scripts/generate-policy.sh:298`); both generator scripts emit PolicyGenerator structure.

### How the ApplicationSet actually discovers policies

**Verified against `autoshift/templates/autoshift-app-set.yaml` and a live hub, 2026-08-12.**
`CLAUDE.md` still describes this as a `directories: - path: 'policies/*'` wildcard. That is wrong
and must not be repeated.

Git mode uses **2 `git` generators, both `files:` matchers**, not a directory generator:

1. `policies/stable/*/kustomization.yaml`, plus the same for `certified` and `community`.
   These are the PolicyGenerator directories, rendered by the CMP sidecar.
2. `policies/stable/*/Chart.yaml`, plus `certified` and `community`.
   These are the 4 Helm holdouts.

Both exclude deeper paths (`policies/*/*/*/kustomization.yaml`). A directory matches exactly one
generator, because a policy migrated to PolicyGenerator drops its `Chart.yaml`. That is the
mechanism routing each directory to the right source type.

Note the 3 tiers. Paths are `policies/<tier>/<name>/`, never a flat `policies/<name>/`.

The `list` generator over `files/policy-list.txt` exists **only** in OCI mode, gated behind
`{{- if .Values.autoshiftOciRegistry }}`.

Therefore `jsonpath='{.spec.generators[0].git.directories[0].path}'` returns nothing. To inspect
the generator, read `.spec.generators[0].git.files[*].path`.

### Naming rules for generated objects

Get these exactly right. They are computed, not literal, and guessing produces commands that
fail:

- **Argo CD Applications** are named `{{ .Release.Name }}-{{ .path.basename }}`
  (`autoshift/templates/autoshift-app-set.yaml:80`). With release name `autoshift`, the
  cluster-labels Application is **`autoshift-cluster-labels`**, not `cluster-labels`. Same for
  every other policy: `autoshift-policy-foundation`, `autoshift-nmstate`, and so on.
- **The ApplicationSet** is `{{ .Release.Name }}-policies`, so `autoshift-policies`.
- **The policy namespace** is `policies-{{ .Release.Name }}`, so `policies-autoshift`.
- **cluster-labels policies** are `policy-<target>-labels` with the target lowercased
  (`policy-cluster-labels.yaml:19`), giving `policy-selfmanagedhub-labels`,
  `policy-managedhub-labels`, `policy-managedcluster-labels`. Placements prefix that with
  `placement-`, giving `placement-policy-selfmanagedhub-labels`.
- **The ManagedClusterSet** is created by the `policy-foundation` chart
  (`policies/stable/policy-foundation/templates/managed-cluster-set.yaml`).
- The Argo CD instance is **`infra-gitops`** in namespace `openshift-gitops`.

### The label flow

Labels are **only** defined in values files. They are never applied to managed cluster objects by
hand. This rule is the spine of the lab.

1. Labels set in `autoshift/values/clustersets/*.yaml` or `values/clusters/*.yaml`
2. The `cluster-labels` Argo CD Application renders them into ConfigMaps (`cluster-set.{name}`,
   `managed-cluster.{name}`) in the policy namespace
3. The `cluster-labels` policy looks those ConfigMaps up at runtime and stamps the resolved labels
   onto each `ManagedCluster`
4. Other policies select clusters by those labels through Placement predicates

`config:` blocks are rendered into a ConfigMap named **`{clusterName}.rendered-config`** on the
hub, built by `policies/stable/cluster-config-maps/templates/policy-rendered-config-maps.yaml`.
The cluster name comes first. Do not write it as `rendered-config.{cluster}`.

Precedence: **cluster-specific > clusterset > existing non-autoshift labels**. Enforcement is
`mustonlyhave`, so an `autoshift.io/*` label removed from the values file is removed from the
cluster. That is why deletion propagates.

Two labels are stamped automatically and are not user-configurable:
`autoshift.io/owning-namespace` and `autoshift.io/owning-deployment`.

### Three-phase deployment

1. Bootstrap OpenShift GitOps and ACM by `helm install`
2. Create an Argo CD Application pointing at the `autoshift/` chart
3. The ApplicationSet auto-discovers and deploys every chart under `policies/*`

After phase 3 the GitOps and ACM policies take over management of the operators bootstrapped in
phase 1. **ACM must be bootstrapped before GitOps**, because the repo-server's PolicyGenerator CMP
init-container image is resolved by a render-time lookup of ACM's
`multicluster-operators-hub-subscription` deployment. `docs/quickstart.md` has the order wrong.
Recovery is `helm upgrade` on gitops once ACM is up.

### The five-label operator contract

Every operator policy is configured by the same label set:

- `<component>: 'true'` enables it
- `<component>-subscription-name` is the OLM package name
- `<component>-channel`
- `<component>-source` (default `redhat-operators`)
- `<component>-source-namespace` (default `openshift-marketplace`)
- `<component>-version` optionally pins the CSV.

**Version pinning — settled empirically against a live hub, 2026-08-12.** This entry was wrong
twice before. Read all of it.

Observed on sandbox1313, which runs AutoShift with 21 OperatorPolicies:

- `install-operator-node-maintenance` is the only policy with `versions` set
  (`["node-maintenance-operator.v5.5.0"]`). Its `upgradeApproval` is `Automatic`, and its
  Subscription `node-maintenance-operator` has **`installPlanApproval: Manual`**.
- The other 20 policies have `versions: []` and every one of their Subscriptions is `Automatic`.

So both halves are true at once, and the lab must state both:

1. The OperatorPolicy's own `upgradeApproval` field stays `Automatic`. There is no `Manual` in
   that enum.
2. ACM, seeing a pinned `versions` allow-list, sets the **managed Subscription** to
   `installPlanApproval: Manual`. That is the runtime enforcement, and the learner WILL see it.

The mechanism is: the `-version` label feeds `startingCSV` and the `versions` allow-list; ACM then
holds the Subscription at manual approval so OLM cannot upgrade past the allowed set.

Supporting comment from `components/operator-install/templates/operator.yaml:38-40`, which is
about the policy field only, not about the resulting Subscription:

> `upgradeApproval` (optional): defaults to Automatic. The OperatorPolicy enum is None|Automatic
> (there is **no Manual** — pin a version via `versions` for manual-approval *behavior*).

Note that comment describes the **policy** field, and the parenthetical "pin a version via
`versions` for manual-approval behavior" is exactly what the live cluster shows: the behaviour
arrives as a Manual Subscription.

What happens when you set `<component>-version`: the policy feeds that value into both
`startingCSV` and the OperatorPolicy's `versions` allow-list
(`policies/stable/node-feature-discovery/manifests/operator-install/kustomization.yaml:23-33`).
The policy's `upgradeApproval` stays `Automatic`, and ACM sets the managed Subscription to
`installPlanApproval: Manual` so OLM cannot move past the allowed set.

Teach the observable outcome and have the learner read the resulting Subscription and
OperatorPolicy rather than asserting a specific `installPlanApproval` value.

`-subscription-name` is the canonical key because `scripts/generate-imageset-config.sh` discovers
which operators to mirror by reading it. That is the concrete answer to "why is that label
mandatory?"

## Environment and lab shape

- One hub cluster, self-managed as `local-cluster`. No spoke required.
- Install via the local Helm dev path: `helm upgrade --install autoshift ./autoshift -f ...`.
  Endorsed by `docs/quickstart.md` for demos. Edit values, re-apply, observe. No fork, no push.
- Start from `hub-minimal.yaml`, not `hub.yaml`. `hub-minimal.yaml` is a short file enabling only
  GitOps and ACM, so the learner adds one feature at a time and watches each appear. `hub.yaml`
  turns on roughly thirty operators up front and buries the mechanism.
- Release names must be **11 characters or fewer** (`helm template autoshift ./autoshift ...`);
  the default `release-name` produces a 21-character policy namespace and trips AutoShift's own
  naming validator.
- `policy_namespace` is always overridden by the ApplicationSet to `policies-{Release.Name}`.

## Module content

**Module 1, bootstrap (~30 min).** Clone, ACM, GitOps, AutoShift. Teach the ACM-before-GitOps
ordering with the real cause and the real error. Close on the ApplicationSet fan-out.

**Module 2, label flow (~25 min).** Staged so that nothing happens first: no clusterset means no
labels means no policies. Then assign the clusterset and trace the whole chain, `cluster-set.hub`
ConfigMap to `ManagedCluster` labels to Placement to PlacementDecision to Policy.

**Module 3, enable a feature (~30 min).** Node Feature Discovery. Small, fast, and set to
`node-feature-discovery: 'false'` at `hub.yaml:391` with a commented-out `-version` line directly
below it. `hub-minimal.yaml` does not mention NFD at all, so the learner adds all five labels.
Then pin the version and observe the manual InstallPlan approval. Then turn it back off.

**Module 4, config blocks and overrides (~25 min).** `hub-minimal.yaml` has no `config:` block, so
the learner adds one and reads the value back out of the rendered-config ConfigMap. Then a
per-cluster override proving cluster beats clusterset. Labels versus `config:` blocks matters
because ACM's `OperatorPolicy` can only read `ManagedCluster` labels.

**Module 5, operate and troubleshoot (~30 min).** The diagnostic commands, each annotated with the
question it answers. `autoshift.dryRun: true` as the fleet-wide safety switch. Policy dependency
chains as structural safety. Ends with deliberate breakage: remove a `-channel` label, diagnose the
NonCompliant OperatorPolicy, fix it.

**Module 6, author a policy (~30 min).** `scripts/generate-operator-policy.sh`, read the scaffolded
files, `kustomize build` to watch them become Policy plus Placement plus PlacementBinding, then
`cd tools && go test -tags integration ./internal/resolver/...`. An `autoshift.io/*` label consumed
by a policy but absent from `autoshift/values/clustersets/_example.yaml` **fails CI**. `tools/` is
its own Go module, so the test must run from inside it.

**Module 7, OCI and disconnected (~60 min, heaviest).**

*Exercise 1.* Use AutoShift to install Quay on the lab cluster, publish AutoShift's own OCI
artifacts into it, then redeploy AutoShift from it. Viable on a single cluster because
`odf-multi-cloud-gateway: 'standalone'` brings up NooBaa only, with no Ceph and no three storage
nodes, and has its own placement at
`policies/stable/openshift-data-foundation/placement-odf-standalone.yaml`. The shipped
`QuayRegistry` CR sets `objectstorage: managed: true`, which NooBaa satisfies. The policy also runs
a `create-admin-user` Job and creates a `ConsoleLink`.

The in-cluster registry serves a cluster-ingress certificate the client will not trust, which is
where `gitops-cluster-ca-bundle: 'true'` becomes a hands-on step. Publish with
`make render-policy-charts` then `make push-charts VERSION=... REGISTRY=<quay-route>`. Do **not**
use `make release`, which also rewrites chart versions across the working tree. Then redeploy as an
OCI Application and watch the ApplicationSet swap from the git directory generator to the list
generator over `autoshift/files/policy-list.txt`, with no CMP sidecar involved.

State the cost up front: this needs cluster headroom and around 40 minutes. Two fallbacks, both
stated before the learner starts: inspect the published artifacts on quay.io, or run
`make render-policy-charts` locally to see the PolicyGenerator-to-Helm transformation with no
registry at all.

*Exercise 2, disconnected.* Setting `disconnected-mirror: 'true'` with
`mirror-catalog-suffix: 'mirror'` flips the catalog source of **38 policies** at once through a
shared ternary, visible by diffing the resolved `source:` with no mirror registry in existence.
Then the `config.disconnected` block, which maps one-to-one onto the `disconnected-mirror` policy's
four manifests. Close on the clever part: the values file is the source of truth for what to
mirror, because `scripts/generate-imageset-config.sh` discovers enabled operators dynamically with
no hardcoded list. Callout: the Assisted Installer does not honour IDMS, so a disconnected
`cluster-install` needs its `ClusterImageSet` `releaseImage` pointed at the mirror directly.

**Module 8, fleet operations capstone (~20 min, conceptual).** Four capabilities that all reduce to
clusterset membership: gradual rollout; declarative clusterset assignment, which is owner-guarded
and never steals a cluster, with `git revert` as the rollback; OCP upgrades, where Argo CD health
equals policy compliance, with a warning never to enable `openshift-upgrade` on a populated
clusterset; and hub-of-hubs, where the single rule that a cluster is managed by exactly one ACM
explains why a spoke hub cannot configure itself.

## Diagrams

`site.yml` already wires `@sntke/antora-mermaid-extension`, so diagrams are `[mermaid]` blocks.
See `content/modules/ROOT/pages/content-repo.adoc` in this repo for the syntax. Do not draw ASCII
diagrams in bare `----` listing blocks; that trips `module-reviewer` check C.5 at High severity.

## Things that are wrong elsewhere and must not be repeated

- **Corrected 2026-08-12.** An earlier draft of this file claimed `docs/quickstart.md` gives the
  bootstrap order as GitOps then ACM. That is no longer true and must not be repeated. The
  "Installation from Source" path is now correct: Step 2 installs ACM, Step 3 installs GitOps.
  Only the "Installation from OCI Release" section installs GitOps first, which is valid there
  because OCI mode deploys pre-rendered Helm charts and has no CMP init-container dependency.
  Say that ACM comes first **for source installs**, and do not call the doc wrong.
- `docs/developer-guide.md` Quick Start shows `helm template` on a policy directory. That fails on
  a PolicyGenerator directory.
- Earlier drafts of this lab plan said `quay-channel: stable-3.17`. It is **`stable-3.18`**.
- Never state a policy count. Policies are added frequently; use "ACM policies", not a number.
- Never suggest applying a label directly to a `ManagedCluster`.
- Never tell the reader to register a policy in the ApplicationSet. Discovery is automatic through
  the `policies/*` wildcard.
