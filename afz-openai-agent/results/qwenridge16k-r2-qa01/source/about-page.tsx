import type { Metadata } from "next";
import Link from "next/link";
import CTA from "@/components/CTA";

export const metadata: Metadata = {
  title: "About",
  description:
    "About AFZ Engineering Inc.: our mission, engineering philosophy and the types of clients we typically serve across Ontario.",
};

export default function AboutPage() {
  return (
    <>
      <section className="page-hero">
        <div className="container">
          <h1>About AFZ Engineering</h1>
          <p>
            An Ontario mechanical engineering consultancy focused on clear,
            code-informed and practical design.
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="mission-heading">
        <div className="container">
          <div className="two-col">
            <div className="lead-card">
              <h2 id="mission-heading">Our mission</h2>
              <p>
                We exist to deliver mechanical engineering that is accurate,
                well documented and practical to build. Our goal is to give
                clients confidence that their systems will perform as intended,
                meet applicable codes and support the long-term operation of the
                building.
              </p>
              <p>
                We approach every project as a coordination problem as much as a
                technical one, working closely with architects, contractors and
                other consultants to keep the design coherent from concept
                through permit and construction.
              </p>
            </div>
            <div className="lead-card">
              <h2>Engineering philosophy</h2>
              <p>
                <strong>Code-informed.</strong> We design against the Ontario
                Building Code, ASHRAE, CSA B149, NFPA 96 and HRAI principles so
                that the work stands up to review.
              </p>
              <p>
                <strong>Right-sized.</strong> Accurate heat loss and heat gain
                work means equipment is sized for real conditions, not
                assumptions.
              </p>
              <p>
                <strong>Documented.</strong> Clear drawings, calculations and
                specifications reduce ambiguity for everyone downstream.
              </p>
              <p>
                <strong>Practical.</strong> We balance performance,
                constructability and lifecycle cost to deliver systems that are
                practical to build and operate.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="section section-soft" aria-labelledby="clients-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="clients-heading">Typical clients</h2>
            <p>
              We work with a range of clients across Ontario. Typical
              engagements include:
            </p>
          </div>
          <div className="card-grid">
            <div className="card">
              <h3>Developers & Owners</h3>
              <p>
                Owners and developers of commercial, institutional and
                industrial buildings seeking mechanical design and permit
                support.
              </p>
            </div>
            <div className="card">
              <h3>Architects</h3>
              <p>
                Architectural firms coordinating mechanical scope with overall
                building design.
              </p>
            </div>
            <div className="card">
              <h3>Contractors</h3>
              <p>
                Mechanical and general contractors who need design detail and
                documentation to support construction.
              </p>
            </div>
            <div className="card">
              <h3>Restaurants & Food Service</h3>
              <p>
                Operators and owners of commercial kitchens requiring exhaust,
                make-up air and related mechanical design.
              </p>
            </div>
            <div className="card">
              <h3>Municipal & Institutional</h3>
              <p>
                Schools, community and civic buildings with ventilation, comfort
                and code requirements.
              </p>
            </div>
            <div className="card">
              <h3>Existing Building Owners</h3>
              <p>
                Owners upgrading or replacing HVAC, hydronic, plumbing or gas
              </p>
            </div>
          </div>
        </div>
      </section>

      <CTA />
    </>
  );
}