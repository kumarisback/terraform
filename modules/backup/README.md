# backup

AWS Backup for an environment (roadmap step 25, learning topic 25): a vault (optionally
locked), a plan with a daily rule (35 days) and a monthly one (a year), an optional copy of
each daily to another vault (another region or account), a selection of every RDS instance,
EBS volume and EFS file system tagged `Backup=daily`, and SNS notifications for failed jobs
and finished restores. Used by `infrastructure/app-cluster/01-infra` (`enable_aws_backup`).
