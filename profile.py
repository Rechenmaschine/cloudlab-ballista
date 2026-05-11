"""Ballista distributed experiment.

1 scheduler + N executors on a (shapeable) LAN.

Storage layout:
  /              OS, Rust, apt packages.       Standard CloudLab image.
  /mnt/work      Ballista source + build,      Ephemeral Blockstore.
                 executor --work-dir.          Fresh every experiment.
  /mnt/data      Dataset (executors).          Ephemeral Blockstore,
                                               optionally pre-populated
                                               from datasetURN.

A new ballistaRef triggers a clean from-scratch Ballista build (since
/mnt/work is recreated empty each experiment). Data is either prepped
fresh on the first experiment (then captured into an Image-Backed
Dataset via CloudLab UI), or auto-loaded from that dataset on every
experiment after.

Knobs of note:
  - linkBandwidth/Latency/Plr: artificially throttle the LAN.
  - concurrentTasks: cap per-executor parallelism (--concurrent-tasks).
  - datasetURN: Image-Backed Dataset to auto-populate /mnt/data.
"""

import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()
request = pc.makeRequestRSpec()

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
pc.defineParameter(
    "nExecutors", "Number of Ballista executors",
    portal.ParameterType.INTEGER, 4)

pc.defineParameter("phystype", "Physical node type (blank=any)",
                   portal.ParameterType.NODETYPE, "",
                   longDescription="e.g. `c220g2`, `c6420`, `xl170`.")

imageList = [
    ('default', 'Default Image (cluster picks)'),
    ('urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD', 'Ubuntu 24.04'),
    ('urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD', 'Ubuntu 22.04'),
    ('urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU20-64-STD', 'Ubuntu 20.04'),
]
pc.defineParameter("osImage", "OS image",
                   portal.ParameterType.IMAGE, imageList[2], imageList,
                   longDescription="`setup.sh` assumes **apt** (Debian/Ubuntu). "
                                   "**Ubuntu 22.04** is the most broadly available "
                                   "across CloudLab clusters.")

# ---------------------------------------------------------------------------
# Ballista
# ---------------------------------------------------------------------------
pc.defineParameter(
    "ballistaRepo", "Ballista repo URL (default: upstream Apache Ballista)",
    portal.ParameterType.STRING,
    "https://github.com/apache/datafusion-ballista.git",
    longDescription="Leave default for upstream, or point at your fork.")

pc.defineParameter(
    "ballistaRef", "Branch, tag, or commit SHA to check out",
    portal.ParameterType.STRING, "main",
    longDescription="A branch (`main`) or tag (`v0.12.0`) always fetches the "
                    "current tip; a full or short commit SHA pins it.")

pc.defineParameter(
    "concurrentTasks", "Concurrent tasks per executor (0 = all CPU cores)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Passed to `ballista-executor` as `--concurrent-tasks`. "
                    "Lower it to study scheduler queueing or simulate slow nodes.")

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
pc.defineParameter(
    "datasetURN",
    "Image-Backed Dataset URN to pre-populate /mnt/data (blank = empty)",
    portal.ParameterType.STRING, "",
    longDescription="If set, every executor's `/mnt/data` Blockstore is "
                    "initialized from this dataset (one-time create via "
                    "CloudLab UI after staging the data on a first run). "
                    "**Leave blank on the first experiment.**")

pc.defineParameter(
    "dataDiskSize", "Size of the /mnt/data Blockstore per executor (GB)",
    portal.ParameterType.INTEGER, 20,
    longDescription="Must be **>= the dataset content size**. Still allocated "
                    "when no dataset is set.")

pc.defineParameter(
    "workDiskSize", "Ephemeral /mnt/work Blockstore size per node (GB)",
    portal.ParameterType.INTEGER, 30,
    longDescription="Holds Ballista source + `cargo` build `target/` AND "
                    "(on executors) the `--work-dir` for shuffle/spill. "
                    "Blockstores are **NOT** captured in disk-image snapshots "
                    "and are recreated empty for every new experiment, so "
                    "switching `ballistaRef` always triggers a clean build.")

# ---------------------------------------------------------------------------
# Network shaping
# ---------------------------------------------------------------------------
pc.defineParameterGroup("network", "Network")

pc.defineParameter(
    "linkBandwidth", "LAN bandwidth limit in Kbps (0 = unlimited)",
    portal.ParameterType.INTEGER, 0, groupId="network",
    longDescription="Examples: `100000` = 100 Mb/s, `1000000` = 1 Gb/s, "
                    "`10000000` = 10 Gb/s. Activates Emulab link shaping "
                    "(**dummynet**).")

pc.defineParameter(
    "linkLatency", "Added one-way LAN latency in ms (0 = none)",
    portal.ParameterType.INTEGER, 0, groupId="network")

pc.defineParameter(
    "linkPlr", "LAN packet loss rate (0 = none)",
    portal.ParameterType.LOSSRATE, 0.0, groupId="network",
    longDescription="e.g. `0.01` = 1% loss.")

params = pc.bindParameters()

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if params.nExecutors < 1 or params.nExecutors > 32:
    pc.reportError(portal.ParameterError(
        "nExecutors must be 1-32.", ["nExecutors"]))

if params.concurrentTasks < 0:
    pc.reportError(portal.ParameterError(
        "concurrentTasks must be >= 0.", ["concurrentTasks"]))

pc.verifyParameters()

# ---------------------------------------------------------------------------
# LAN with optional shaping
# ---------------------------------------------------------------------------
net = request.LAN("ballistaLan")

shape = {k: v for k, v in [("bandwidth", params.linkBandwidth),
                            ("latency", params.linkLatency),
                            ("plr", params.linkPlr)] if v}
if shape:
    net.setProperties(**shape)

# ---------------------------------------------------------------------------
# Node factory
# ---------------------------------------------------------------------------
def make_node(name, role):
    n = request.RawPC(name)

    if params.osImage and params.osImage != "default":
        n.disk_image = params.osImage
    if params.phystype:
        n.hardware_type = params.phystype

    iface = n.addInterface("eth1")
    net.addInterface(iface)

    # Every node gets an ephemeral Blockstore at /mnt/work. Holds the
    # Ballista clone + build (so each experiment gets a clean from-scratch
    # build) and, on executors, a subdir used as --work-dir. NOT captured
    # in disk-image snapshots - that's the whole point.
    bs = n.Blockstore(name + "-work", "/mnt/work")
    bs.size = str(params.workDiskSize) + "GB"
    bs.placement = "any"

    # Executors get a SECOND Blockstore at /mnt/data for the dataset.
    # If datasetURN is set, CloudLab initializes this Blockstore from
    # that Image-Backed Dataset at boot (each executor gets its own local
    # clone - no fan-out needed). If unset, /mnt/data starts empty and
    # you populate it yourself on the first experiment.
    if role == "executor":
        data_bs = n.Blockstore(name + "-data", "/mnt/data")
        data_bs.size = str(params.dataDiskSize) + "GB"
        data_bs.placement = "any"
        if params.datasetURN:
            data_bs.dataset = params.datasetURN

    n.addService(pg.Execute(
        shell="bash",
        command=(
            "sudo -E bash /local/repository/setup.sh " +
            role + " " +
            params.ballistaRepo + " " +
            params.ballistaRef + " " +
            str(params.concurrentTasks))))
    return n

make_node("scheduler", "scheduler")
for i in range(params.nExecutors):
    make_node("executor-" + str(i), "executor")

pc.printRequestRSpec(request)
