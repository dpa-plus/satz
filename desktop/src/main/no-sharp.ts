// transformers.js loads sharp for pictures, which satz never gives it. This
// stands in for it in the bundle (build.mjs), and package.json's `files` keeps
// sharp and its native libraries (@img) out of the package, so the image
// library neither runs nor ships.
export default {}
