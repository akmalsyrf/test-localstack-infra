import json


def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "message": "testinfra-api localstack ok",
                "path": event.get("path") or event.get("rawPath"),
                "requestId": getattr(context, "aws_request_id", None),
            }
        ),
    }
