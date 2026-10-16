# A live box keeps the image it runs

**Status:** Proposed. Built: the plain `AmiId` parameter in `box.yaml` and the image lookup in `make stacks`. Date: 2026-10-15.

## Context

The box stack declared `AmiId` as `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` defaulting to the public Amazon Linux
`al2023-ami-kernel-default-<arch>` key, with a description saying never to re-resolve it on a live box. Nothing enforced that.
`make stacks` runs `aws cloudformation deploy`, and every deploy resolves an SSM-typed parameter again, so any update to a live box
(a new security group rule, a changed volume size) found the newest image, changed the `Box` instance's `ImageId`, and made
CloudFormation replace the instance and its Elastic IP association. `UsePreviousValue` does not help, because it also re-resolves.
The public image key's older versions cannot be read, so pinning the key to a version is not possible either. A change set previewed
the replacement before it ran.

## Decision

1. **`AmiId` is `Type: AWS::EC2::Image::Id` with no default.** A template can no longer resolve an image by itself; every deploy
   names one.
2. **`make stacks` supplies it, and the rule lives there.** In order: an explicit `AMI_ID=ami-...` wins; otherwise the image of the
   instance the box stack's `Box` resource currently names; otherwise, only when the box stack does not exist yet, the latest image
   from the public key. The recipe echoes which image it uses and whether it is given, pinned or new, and stops before changing the
   box stack when no `ami-` id comes out. A stack that exists but whose instance cannot be read stops too, rather than falling back
   to the newest image.
3. **Upgrading an image is deliberate.** `make stacks AMI_ID=ami-...` replaces the instance on purpose; the guide says to preview
   the change set first.
4. **No bluebook change.** The choice of image is not a fact about the domain or the `BoxTarget` aggregate: it is a runtime fact
   of the deployed stack, read from AWS at deploy time, so no attribute or refusal can hold it. Rehearsal needs nothing extra: a
   rehearsal makes a new stack, which has no running box, so it takes the latest image.

## Consequences

- Every `AwsBox` world's `box.yaml` and `Makefile` change. A box deployed from the older template needs one `make stacks` to adopt
  the plain parameter, and it keeps the image it runs.
- A first deploy still gets the newest image at that moment, and a box then stays on it until someone asks for another.
- The recipe needs `aws ec2 describe-instances` and `ssm:GetParameter` on the public key in the deployer's permissions.
