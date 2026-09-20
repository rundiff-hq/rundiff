import { FormEvent, useState } from "react";

type Review = {
  id: string;
  projectId: string;
  scenarioId: string;
  baselineSha: string;
  candidateSha: string;
  status: string;
  decision: string | null;
  result: unknown;
};

export function App() {
  const [reviewId, setReviewId] = useState("");
  const [review, setReview] = useState<Review | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function loadReview(event: FormEvent) {
    event.preventDefault();
    setError(null);

    const response = await fetch(`/api/reviews/${reviewId.trim()}`);
    const payload = await response.json() as { review?: Review; error?: string };

    if (!response.ok || !payload.review) {
      setReview(null);
      setError(payload.error ?? "Unable to load review");
      return;
    }

    setReview(payload.review);
  }

  return (
    <main>
      <header>
        <span className="eyebrow">RunDiff / Cloudflare Control Plane</span>
        <h1>Behavioral Review</h1>
        <p>
          First production implementation: portable domain, Cloudflare-native runtime.
        </p>
      </header>

      <form onSubmit={loadReview}>
        <input
          value={reviewId}
          onChange={(event) => setReviewId(event.target.value)}
          placeholder="Review ID"
          aria-label="Review ID"
        />
        <button type="submit">Open review</button>
      </form>

      {error && <p className="error">{error}</p>}

      {review && (
        <section>
          <div className="decision">{review.decision ?? review.status}</div>
          <dl>
            <dt>Project</dt><dd>{review.projectId}</dd>
            <dt>Scenario</dt><dd>{review.scenarioId}</dd>
            <dt>Baseline</dt><dd><code>{review.baselineSha}</code></dd>
            <dt>Candidate</dt><dd><code>{review.candidateSha}</code></dd>
            <dt>Status</dt><dd>{review.status}</dd>
          </dl>
          {review.result != null && (
            <pre>{JSON.stringify(review.result, null, 2)}</pre>
          )}
        </section>
      )}
    </main>
  );
}
