// S3 Bucket with a Lifecycle Policy that will delete old items
resource "aws_s3_bucket" "this" {
  bucket = "${var.log_bucket_name}"
  acl    = "private"

  lifecycle_rule {
    id      = "auto-delete-after-${var.expiration_days}-days"
    prefix  = ""
    enabled = true

    expiration {
      days = "${var.expiration_days}"
    }
  }

  logging {
    target_bucket = "${aws_s3_bucket.logs.id}"
    target_prefix = "log/"
  }

  tags = "${var.tags}"
}

// S3 Bucket with a Lifecycle Policy that will delete old items
resource "aws_s3_bucket" "logs" {
  bucket = "${var.log_bucket_name}-log"
  acl    = "private"
  tags   = "${var.tags}"
}

// Policy for the bucket with READ and LIST permissions given to the read access account, Other accounts
// Belonging to the organizaion are only allowed to Put objects to this bucket .

resource "aws_s3_bucket_policy" "this" {
  bucket = "${aws_s3_bucket.this.id}"

  policy = <<POLICY
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Sid": "splunk_access",
         "Effect": "Allow",
         "Principal": {
            "AWS" : "arn:aws:iam::${var.read_access_account}:root"
         },
         "Action": [
            "s3:Get*",
            "s3:List*"
         ],
         "Resource": [
            "arn:aws:s3:::${var.log_bucket_name}/*"
         ]
      },
      {
         "Sid": "all_accounts_in_organization_can_put_object_access",
         "Effect": "Allow",
         "Principal": "*",
         "Action": [
            "s3:Put*"
         ],
         "Condition": {
            "StringEquals":
                {
                "aws:PrincipalOrgID":["${var.aws_organization_id}"],
                "s3:x-amz-acl": ["bucket-owner-full-control"]
                }
         },
         "Resource": [
            "arn:aws:s3:::${var.log_bucket_name}/*"
         ]
      }
   ]
}
POLICY
}

resource "aws_s3_bucket_notification" "on_new_object" {
  bucket = "${aws_s3_bucket.this.id}"

  topic {
    topic_arn = "${aws_sns_topic.new_object_event.arn}"

    events = [
      "s3:ObjectCreated:*",
    ]

    filter_suffix = ""
  }
}

resource "aws_sns_topic" "new_object_event" {
  name = "s3-notification-topic-${var.log_bucket_name}"
}

resource "aws_sns_topic_policy" "this" {
  arn    = "${aws_sns_topic.new_object_event.arn}"
  policy = "${data.aws_iam_policy_document.bucket_can_publish.json}"
}

data "aws_iam_policy_document" "bucket_can_publish" {
  statement {
    actions = [
      "SNS:Publish",
    ]

    effect = "Allow"

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"

      values = [
        "${aws_s3_bucket.this.arn}",
      ]
    }

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      "${aws_sns_topic.new_object_event.arn}",
    ]

    sid = "allowpublish"
  }

  statement {
    actions = [
      "SNS:Subscribe",
      "SNS:Receive",
    ]

    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnEquals"
      values   = ["${aws_sqs_queue.new_s3_object.arn}"]
      variable = "aws:SourceArn"
    }

    resources = [
      "${aws_sns_topic.new_object_event.arn}",
    ]

    sid = "sid_allow_subscribe"
  }
}

// Queue that Splunk will subscribe to
resource "aws_sqs_queue" "new_s3_object" {
  name                       = "new-objects-for-${var.log_bucket_name}"
  visibility_timeout_seconds = "${var.sqs_visibility_timeout_seconds}"
  message_retention_seconds  = "${var.sqs_message_retention_seconds}"
  receive_wait_time_seconds  = "${var.sqs_receive_wait_time_seconds}"
  redrive_policy             = "{\"deadLetterTargetArn\":\"${aws_sqs_queue.dlq.arn}\",\"maxReceiveCount\":4}"
  tags                       = "${var.tags}"
}

data "aws_iam_policy_document" "sns_topic_can_publish" {
  statement {
    effect = "Allow"

    principals {
      identifiers = [
        "*",
      ]

      type = "AWS"
    }

    actions = [
      "SQS:SendMessage",
    ]

    resources = [
      "${aws_sqs_queue.new_s3_object.arn}",
    ]

    condition {
      test = "ArnEquals"

      values = [
        "${aws_sns_topic.new_object_event.arn}",
      ]

      variable = "aws:SourceArn"
    }
  }
}

// Dead Letter queue, use same parameters as main queue
resource "aws_sqs_queue" "dlq" {
  name                      = "new-objects-for-${var.log_bucket_name}-dlq"
  message_retention_seconds = "${var.sqs_message_retention_seconds}"
  receive_wait_time_seconds = "${var.sqs_receive_wait_time_seconds}"
  tags                      = "${var.tags}"
}

resource "aws_sqs_queue_policy" "bucket_can_publish" {
  policy    = "${data.aws_iam_policy_document.sns_topic_can_publish.json}"
  queue_url = "${aws_sqs_queue.new_s3_object.id}"
}

resource "aws_sns_topic_subscription" "bucket_change_notification_to_queue" {
  topic_arn = "${aws_sns_topic.new_object_event.arn}"
  protocol  = "sqs"
  endpoint  = "${aws_sqs_queue.new_s3_object.arn}"
}
