// install karpenter CRDS
// install karpenter
// create default ec2 nodeclass and default nodepool
locals {
  karpenter = {
    cluster_name          = local.cluster_name
    namespace             = "kube-system"
    version               = var.karpenter_version
    discovery_key         = "karpenter.sh/discovery"
    discovery_value       = local.cluster_name
    instance_profile_name = "KarpenterNodeInstanceProfile-${local.cluster_name}"
    zone_prefix           = join("-", slice(split("-", var.region), 0, 1))
  }
}

# Keep a stable instance profile name for the EC2NodeClass and manage the
# backing node role in the root module so applies cannot detach the Karpenter
# node policies via upstream attachment replacement.
resource "aws_iam_instance_profile" "karpenter" {
  name = local.karpenter.instance_profile_name
  role = aws_iam_role.karpenter_node.name
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.33.1"

  cluster_name = local.karpenter.cluster_name
  namespace    = local.karpenter.namespace

  # Root-manage the node IAM role so Terraform can move the existing
  # attachments in place before we switch to an exclusive attachment set.
  create_node_iam_role = false
  node_iam_role_arn    = aws_iam_role.karpenter_node.arn

  create_instance_profile = false

  enable_v1_permissions = true

  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]
  iam_role_tags = merge(local.tags, {
    karpenter = true
  })

  queue_name = "karpenter-${var.nuon_id}"

  depends_on = [
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
  ]
}

resource "helm_release" "karpenter_crd" {
  provider = helm.main

  namespace        = local.karpenter.namespace
  create_namespace = false

  chart      = "karpenter-crd"
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  version    = local.karpenter.version

  wait = true

  values = [
    yamlencode({
      karpenter_namespace = local.karpenter.namespace
      webhook = {
        enabled     = true
        serviceName = "karpenter"
        port        = 8443
      }
    }),
  ]

  depends_on = [
    module.karpenter
  ]
}

resource "helm_release" "karpenter" {
  provider = helm.main

  namespace        = local.karpenter.namespace
  create_namespace = false

  chart      = "karpenter"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  version    = local.karpenter.version

  # https://github.com/aws/karpenter-provider-aws/blob/v1.2.2/charts/karpenter/values.yaml
  values = [
    yamlencode({
      replicas : var.karpenter_replica_count
      logLevel : "debug"
      settings : {
        clusterEndpoint : module.eks.cluster_endpoint
        clusterName : local.karpenter.cluster_name
        interruptionQueue : module.karpenter.queue_name
        batchMaxDuration : "15s" # a little longer than the default
      }
      dnsPolicy : "ClusterFirst"
      controller : {
        resources : {
          requests : {
            cpu : 1
            memory : "1Gi"
          }
          limits : {
            cpu : 1
            memory : "1Gi"
          }
        }
      }
      serviceAccount : {
        annotations : {
          "eks.amazonaws.com/role-arn" : module.karpenter.iam_role_arn
        }
      }
    }),
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }

  depends_on = [
    helm_release.karpenter_crd
  ]
}

#
# EC2NodeClass: default
# https://karpenter.sh/v1.0/concepts/nodeclasses/
#
locals {
  # https://karpenter.sh/v1.0/concepts/nodeclasses/#specamiselectorterms
  default_nodeclass_default_ami_selector_terms = [
    {
      alias = "al2023@latest"
    }
  ]
  # terraform's dumb type system gets confused if we use a ternary (x ? x : y)
  # to choose between these, so we have do trick it with a conditional list
  # index. bad terraform.
  default_nodeclass_ami_selector_terms = [
    var.karpenter_default_nodeclass_ami_selector_terms,
    local.default_nodeclass_default_ami_selector_terms,
  ][var.karpenter_default_nodeclass_ami_selector_terms != null ? 0 : 1]
}

// Karpenter teardown ordering
// ===========================
// Terraform destroys in reverse dependency order. The chain below ensures that
// during teardown, the NodePool is deleted first (triggering Karpenter to drain
// nodes), then we wait for all EC2 instances to terminate, and only then delete
// the EC2NodeClass, Helm release, and supporting IAM/tag resources.
//
// Create order (follows depends_on):
//   helm_release.karpenter ──▶ EC2NodeClass ──▶ drain_barrier ──▶ NodePool
//                               ▲
//                               ├── aws_iam_instance_profile.karpenter
//                               └── aws_ec2_tag.private_subnets_karpenter_tags
//
// Destroy order (reverse):
//   NodePool ──▶ drain_barrier (polls EC2) ──▶ EC2NodeClass ──▶ helm_release.karpenter
//
// Why this ordering matters:
// - Karpenter needs the EC2NodeClass to be healthy to process node termination.
//   If the EC2NodeClass is deleted first, Karpenter can't resolve subnets or
//   security groups, leaving NodeClaims stuck with finalizers and EC2 instances
//   orphaned — which then blocks VPC/subnet deletion.
// - The instance profile and subnet discovery tags must also outlive the
//   EC2NodeClass for the same reason.

resource "kubectl_manifest" "karpenter_ec2nodeclass_default" {
  provider = kubectl.main

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      instanceProfile  = local.karpenter.instance_profile_name
      amiSelectorTerms = local.default_nodeclass_ami_selector_terms
      # without this, pods on karpenter nodes can't use the IAM node role
      # https://github.com/aws/karpenter-provider-aws/issues/7548#issuecomment-2558191953
      metadataOptions = var.karpenter_ec2nodeclass_default_metadata_options
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.karpenter.discovery_value
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.karpenter.discovery_value
          }
        }
      ]
      tags = local.tags
    }
  })

  // These dependencies serve double duty:
  // - On create: ensures Karpenter and supporting resources exist before the node class.
  // - On destroy: keeps these resources alive until after the EC2NodeClass is deleted,
  //   so Karpenter can resolve instance profiles, subnets, and security groups during
  //   node termination.
  depends_on = [
    helm_release.karpenter,
    aws_iam_instance_profile.karpenter,
    aws_ec2_tag.private_subnets_karpenter_tags,
  ]
}

// On destroy, explicitly delete all NodeClaims and wait for EC2 instances to
// terminate before deleting the EC2NodeClass or uninstalling Karpenter.
//
// NodePool deletion should cascade to NodeClaims via ownerReferences, but this
// is not deterministic: drains can be blocked by PDBs, do-not-disrupt pods, or
// stuck volume detachments. Explicitly deleting NodeClaims ensures termination
// starts even if the cascade is blocked.
//
// Dependency chain (destroy runs in reverse):
//   NodePool → drain_barrier → EC2NodeClass → helm_release.karpenter → module.eks
resource "terraform_data" "karpenter_drain_barrier" {
  triggers_replace = {
    cluster_ca_data  = module.eks.cluster_certificate_authority_data
    cluster_endpoint = module.eks.cluster_endpoint
    cluster_name     = local.cluster_name
    region           = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp)
      CA_FILE=$(mktemp)
      CLUSTER="${self.triggers_replace.cluster_name}"
      ENDPOINT="${self.triggers_replace.cluster_endpoint}"
      REGION="${self.triggers_replace.region}"

      cleanup() {
        rm -f "$KUBECONFIG_FILE" "$CA_FILE"
      }

      trap cleanup EXIT

      if ! printf '%s' '${self.triggers_replace.cluster_ca_data}' | base64 --decode > "$CA_FILE" 2>/dev/null; then
        printf '%s' '${self.triggers_replace.cluster_ca_data}' | base64 -D > "$CA_FILE"
      fi

      cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: eks
  cluster:
    certificate-authority: $CA_FILE
    server: $ENDPOINT
contexts:
- name: eks
  context:
    cluster: eks
    user: eks
current-context: eks
users:
- name: eks
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
      - eks
      - get-token
      - --region
      - $REGION
      - --cluster-name
      - $CLUSTER
EOF

      karpenter_instances() {
        aws ec2 describe-instances \
          --region "$REGION" \
          --filters \
            "Name=tag:karpenter.sh/nodepool,Values=*" \
            "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' \
          --output text
      }

      # 1. Explicitly delete all NodeClaims as a backup for the NodePool
      #    ownerReference cascade, which can be blocked by PDBs or stuck pods.
      echo "Deleting all NodeClaims..."
      if ! kubectl --kubeconfig "$KUBECONFIG_FILE" delete nodeclaims --all --wait=false 2>&1; then
        echo "WARNING: kubectl delete nodeclaims failed — drain may not proceed cleanly"
      fi

      # 2. Wait for EC2 instances to terminate (up to 15 minutes).
      echo "Waiting for Karpenter instances to terminate..."
      for i in $(seq 1 90); do
        IDS=$(karpenter_instances)
        [ -z "$IDS" ] && echo "All Karpenter instances terminated." && break
        echo "  $(echo $IDS | wc -w | xargs) instances remaining... ($i/90)"
        sleep 10
      done

      # 3. Force-terminate any stragglers.
      IDS=$(karpenter_instances)
      if [ -n "$IDS" ]; then
        echo "WARNING: Force-terminating remaining instances: $IDS"
        aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
      fi

      # 4. Clean up orphaned ENIs left by the VPC CNI plugin. Terminated
      #    instances can leave detached ENIs referencing the node security
      #    group, blocking SG and VPC deletion. We sleep briefly because
      #    ENIs may transition to "available" slightly after the instance
      #    reaches "terminated".
      echo "Waiting for ENIs to settle..."
      sleep 15

      echo "Cleaning up orphaned VPC CNI ENIs..."
      NODE_SGS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
        --query 'SecurityGroups[].GroupId' \
        --output text)
      for sg in $NODE_SGS; do
        ENI_IDS=$(aws ec2 describe-network-interfaces \
          --region "$REGION" \
          --filters "Name=group-id,Values=$sg" "Name=status,Values=available" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text)
        for eni in $ENI_IDS; do
          echo "Deleting orphaned ENI $eni"
          if ! aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni"; then
            echo "WARNING: Failed to delete orphaned ENI $eni"
          fi
        done
      done
    EOT
  }

  depends_on = [
    kubectl_manifest.karpenter_ec2nodeclass_default,
  ]
}

#
# nodepool: default
#
locals {
  default_nodepool_default_spec = {
    limits = {
      cpu    = 100
      memory = "200Gi"
    }
    template = {
      spec = {
        expireAfter = "732h"
        nodeClassRef = {
          group = "karpenter.k8s.aws"
          kind  = "EC2NodeClass"
          name  = "default"
        }
        requirements = [
          {
            key      = "karpenter.sh/capacity-type"
            operator = "In"
            values = [
              "on-demand",
            ]
          },
          {
            "key"      = "node.kubernetes.io/instance-type"
            "operator" = "In"
            "values"   = [var.default_instance_type]
          },
          {
            key      = "topology.kubernetes.io/zone"
            operator = "In"
            values = [ // this requires refinement
              "${var.region}a",
              "${var.region}b",
              "${var.region}c",
            ]
          },
        ]
      }
    }
    # https://karpenter.sh/v1.0/concepts/disruption/
    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "5m"
      budgets = [
        // only allow one node to be disrupted at once
        {
          nodes = "1",
        },
      ]
    }
  }
  # terraform's dumb type system gets confused if we use a ternary (x ? x : y)
  # to choose between these, so we have do trick it with a conditional list
  # index. bad terraform.
  default_nodepool_spec = [
    var.karpenter_default_nodepool_spec,
    local.default_nodepool_default_spec,
  ][var.karpenter_default_nodepool_spec != null ? 0 : 1]
}
resource "kubectl_manifest" "karpenter_nodepool_default" {
  provider = kubectl.main

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = local.default_nodepool_spec
  })

  // On create: transitively depends on EC2NodeClass → helm_release.karpenter.
  // On destroy: this is the first resource deleted, which triggers Karpenter to
  // start draining nodes. The barrier then holds until all instances are gone.
  depends_on = [
    terraform_data.karpenter_drain_barrier,
  ]
}
