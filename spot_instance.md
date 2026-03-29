If you want to use spot instances for your OpenShift cluster on GCP, you can configure the `providerSpec` in your MachineSet or MachineDeployment manifest. Here's an example of how to set it up:

```yaml

providerSpec:
  value:
    machineType: g2-standard-8     # GPU instance type
    onHostMaintenance: Terminate   # Required for GPU instances
    restartPolicy: Never           # Required for GPU instances
    preemptible: true              # means this instance will be a spot instance