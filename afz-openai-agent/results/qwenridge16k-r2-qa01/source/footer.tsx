import Link from "next/link";

export default function Footer() {
  return (
    <footer className="site-footer">
      <div className="container">
        <div className="footer-grid">
          <div>
            <h2>AFZ Engineering Inc.</h2>
            <p>
              Mechanical engineering consultancy serving Ontario. We design HVAC,
              ventilation, heat loss and heat gain, duct, kitchen exhaust and
              make-up air, plumbing, hydronic and gas piping systems, and support
              mechanical permitting.
            </p>
          </div>
          <div>
            <h2>Explore</h2>
            <ul className="footer-nav">
              <li>
                <Link href="/services">Services</Link>
              </li>
              <li>
                <Link href="/projects">Project Types</Link>
              </li>
              <li>
                <Link href="/about">About</Link>
              </li>
              <li>
                <Link href="/contact">Contact</Link>
              </li>
            </ul>
          </div>
          <div>
            <h2>Standards We Work To</h2>
            <p style={{ fontSize: "0.9rem" }}>
              Designs are developed in reference to the Ontario Building Code,
              ASHRAE, CSA B149, NFPA 96 and HRAI principles.
            </p>
          </div>
        </div>
        <div className="footer-bottom">
          <span>Â© {new Date().getFullYear()} AFZ Engineering Inc.</span>
          <span>Ontario, Canada</span>
        </div>
      </div>
    </footer>
  );
}