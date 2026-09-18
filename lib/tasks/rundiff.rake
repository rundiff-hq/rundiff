namespace :rundiff do
  desc "Run RunDiff against its own Rails demo execution"
  task dogfood: "plywo:dogfood"

  desc "Compose two captured executions into one behavioral comparison payload"
  task compare_executions: "plywo:compare_executions"

  desc "Render and optionally publish the durable RunDiff GitHub PR comment"
  task github_comment: "plywo:github_comment"

  desc "Publish the RunDiff behavioral decision as a GitHub Check Run"
  task github_check: "plywo:github_check"
end
