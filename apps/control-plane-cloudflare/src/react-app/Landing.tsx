import landingDocument from "./landing.html?raw";

const styleMatch = landingDocument.match(/<style>([\s\S]*?)<\/style>/i);
const bodyMatch = landingDocument.match(/<body>([\s\S]*?)<\/body>/i);

if (!styleMatch || !bodyMatch) {
  throw new Error("RunDiff landing artifact is malformed");
}

const landingStyles = styleMatch[1];
const landingBody = bodyMatch[1];

export function Landing() {
  return (
    <>
      <style>{landingStyles}</style>
      <div dangerouslySetInnerHTML={{ __html: landingBody }} />
    </>
  );
}
