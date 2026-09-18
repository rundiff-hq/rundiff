class DemoMailer < ApplicationMailer
  def notification(execution_id)
    mail(
      to: "user@example.test",
      subject: "RunDiff demo notification",
      body: "Execution #{execution_id}"
    )
  end
end
