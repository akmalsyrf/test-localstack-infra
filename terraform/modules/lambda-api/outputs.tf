output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}

output "lambda_arn" {
  value = aws_lambda_function.api.arn
}

output "api_id" {
  value = aws_api_gateway_rest_api.api.id
}

output "api_invoke_url" {
  value = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.api.id}/${aws_api_gateway_stage.this.stage_name}/_user_request_/"
}
