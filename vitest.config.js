// The client's own tests. The gem's `spec.files` glob and package.json's
// `files` array both name app/assets/javascripts/*.js explicitly, so
// nothing under spec/js ships in either package.
export default {
  test: {
    environment: "happy-dom",
    include: ["spec/js/**/*.test.js"]
  }
}
