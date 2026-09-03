import type { Metadata } from "next";
import Link from "next/link";
import CTA from "@/components/CTA";

export const metadata: Metadata = {
  title: "Projects",
  description:
    "Representative project types AFZ Engineering Inc. supports: commercial HVAC, institutional buildings, kitchen exhaust, hydronic retrofits, gas piping and mechanical permits.",
};

const PROJECT_TYPES = [
  {
    title: "Commercial HVAC",
    description:
      "New and retrofit HVAC systems for offices, retail, restaurants and light industrial buildings, including equipment selection, duct design and controls.",
  },
  {
    title: "Institutional Buildings",
    description:
      "Mechanical design for schools, community and civic buildings, with emphasis on ventilation, indoor air quality and occupant comfort.",
  },
  {
    title: "Kitchen Exhaust & Make-Up Air",
    description:
      "Exhaust and make-up air systems for commercial kitchens, developed in reference to NFPA 96 principles and Ontario requirements.",
  },
  {
    title: "Hydronic Retrofits",
    description:
      "Replacement and upgrade of hot water heating and cooling systems, including balanced hydraulics and controls modernization.",
  },
  {
    title: "Gas Piping",
    description:
      "Natural gas and propane piping design for new installations and upgrades, in reference to CSA B149 and applicable codes.",
  },
  {
    title: "Mechanical Permits",
    description:
      "Permit-ready documentation for mechanical work, supporting smooth municipal review and construction.",
  },
];

export default function ProjectsPage() {
  return (
    <>
      <section className="page-hero">
        <div className="container">
          <h1>Project Types</h1>
          <p>
            Representative types of work we support. We tailor each engagement to
            the specific scope, site and municipal context of your project.
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="projects-detail">
        <div className="container">
          <div className="section-head">
            <h2 id="projects-detail">How we typically engage</h2>
            <p>
              Most projects begin with a scope discussion, followed by design,
              documentation and permit support. We coordinate with architects,
              contractors and other consultants throughout.
            </p>
          </div>
          <div className="card-grid">
            {PROJECT_TYPES.map((p) => (
              <article className="card" key={p.title}>
                <h3>{p.title}</h3>
                <p>{p.description}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="section section-soft" aria-labelledby="process-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="process-heading">A typical workflow</h2>
            <p>
              A structured process keeps projects on track and documentation
              consistent.
            </p>
          </div>
          <div className="card-grid">
            <div className="card">
              <h3>1 Â· Scope & Consultation</h3>
              <p>
                We define the mechanical scope, constraints and municipal
                requirements for the project.
              </p>
            </div>
            <div className="card">
              <h3>2 Â· Design & Calculations</h3>
              <p>
                Loads, systems and details are developed with supporting
                calculations and code references.
              </p>
            </div>
            <div className="card">
              <h3>3 Â· Documentation & Permits</h3>
              <p>
                Drawings and specifications are produced as a permit-ready set,
                with support through municipal review.
              </p>
            </div>
          </div>
        </div>
      </section>

      <CTA />
    </>
  );
}