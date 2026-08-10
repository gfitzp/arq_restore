# CloudFront CDN infrastructure for arq_restore

Scripts to create and remove the CloudFront distribution that lets arq_restore
download Arq backup data over HTTPS at flat-rate CDN pricing instead of paying
per-GB S3 egress. See the repo discussion of the architecture: private bucket +
Origin Access Control, signed URLs from a trusted key group (with optional IP
condition), and an optional WAF IP allowlist on top.

## Why an S3 access point?

Bucket names containing dots break S3's wildcard TLS certificate for
`bucket.s3.region.amazonaws.com` virtual-host addressing — CloudFront origins
require a valid cert, so pointing a distribution straight at such a bucket
fails with 502s. The setup script instead creates an S3 Access Point on the
bucket and uses its auto-generated, dot-free **alias** as the origin domain (a
documented CloudFront pattern that requires OAC, which we use anyway; it works
equally well for dot-free bucket names). Object access is granted via
bucket-policy delegation to the account's access points plus an access-point
policy scoped to this exact distribution.

## Usage

Run with an AWS profile that has CloudFront, WAFv2, S3 and S3 Control
permissions (a restricted backup-only profile will not have these). The exact
least-privilege permission set is in `iam-cdn-admin-policy_example.json`. To
use it, copy it to `iam-cdn-admin-policy.json` (that filename is git-ignored,
so your filled-in values never enter the repository), replace
`YOUR_BUCKET_NAME`, `YOUR_REGION` and `YOUR_ACCOUNT_ID`, adjust the access
point name if you changed `PREFIX`, and attach it to a dedicated IAM identity:

    cp iam-cdn-admin-policy_example.json iam-cdn-admin-policy.json
    # edit the placeholders, then:
    aws iam put-user-policy --user-name <your-cdn-user> \
        --policy-name arq-restore-cdn-admin \
        --policy-document file://iam-cdn-admin-policy.json

Prefer a separate, temporary IAM identity over widening long-lived backup
credentials; delete that identity (and its policy) once the restore project is
finished.

Then run the setup script, which creates the CloudFront distribution and all
its supporting resources (key pair, key group, access point, OAC, WAF rules,
and bucket/access-point policies):

    ADMIN_PROFILE=youradminprofile BUCKET=your-arq-backup-bucket ./setup-cloudfront-cdn.sh

`BUCKET` (and optionally `REGION`, default us-east-1) is required on the first
run only — it is saved to `~/.arq_restore_cdn/cdn-config.env` and reused by
later runs and by teardown, so no installation-specific values live in the
repository.

The script is idempotent; re-run it after fixing any failure. It prompts before
the one sensitive mutation (adding a delegation statement to the backup
bucket's policy) and backs up any existing policy first. Outputs land in
`~/.arq_restore_cdn/cdn-config.env`:

    CDN_DOMAIN=dxxxxxxxxxxxxx.cloudfront.net
    CDN_KEY_PAIR_ID=KXXXXXXXXXXXXX
    CDN_PRIVATE_KEY=/Users/you/.arq_restore_cdn/cloudfront_private_key.pem
    CDN_DISTRIBUTION_ID=EXXXXXXXXXXXX
    CDN_ALLOWED_CIDRS=x.x.x.x/32

The private key never leaves the machine; arq_restore uses it to sign URLs
locally.

**Separately, and only doable in the CloudFront console:** enroll in a
flat-rate pricing plan ("Pricing plans" page — Pro at $15/month covers 50 TB of
transfer and 10M requests, ample for this workload). Without a plan, transfers
bill at ~$0.085/GB pay-as-you-go rates.

If your public IP changes mid-restore, update the WAF IP set (console → WAF &
Shield → IP sets → `arq-restore-cdn-ipset`) and re-issue signed URLs (automatic,
they're generated per request).

## Teardown

When the restore project is done:

    ADMIN_PROFILE=youradminprofile ./teardown-cloudfront-cdn.sh

Removes the distribution (10–20 min for disable+delete), key group, public
key, OAC, WAF resources, the access point, and the bucket-policy delegation
statement. Local keys and policy backups in `~/.arq_restore_cdn` are kept.
