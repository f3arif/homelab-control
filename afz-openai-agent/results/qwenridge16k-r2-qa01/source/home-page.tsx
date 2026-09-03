import Link from "next/link";
import ServiceCard from "@/components/ServiceCard";
import CTA from "@/components/CTA";
import {
  IconHVAC,
  IconThermo,
  IconDuct,
  IconVent,
  IconKitchen,
  IconPlumb,
  IconHydro,
  IconGas,
  IconPermit,
} from "@/components/Icons";

const SERVICES = [
  {
    title: "HVAC Design",
    description:
      "Commercial and institutional heating, ventilation and air conditioning systems sized for comfort, efficiency and code compliance.",
    icon: <IconHVAC />,
  },
  {
    title: "Heat Loss & Heat Gain",
    description:
      "Envelope and load analysis to size equipment accurately and support energy performance targets.",
    icon: <IconThermo />,
  },
  {
    title: "Duct Design",
    description:
      "Duct sizing, routing and pressure analysis for balanced, low-noise air distribution.",
    icon: <IconDuct />,
  },
  {
    title: "Ventilation",
    description:
      "Outdoor air, occupancy and contaminant-based ventilation strategies for healthy indoor environments.",
    icon: <IconVent />,
  },
  {
    title: "Kitchen Exhaust & Make-Up Air",
    description:
      "Cooking equipment exhaust, capture and make-up air systems aligned with NFPA 96 principles.",
    icon: <IconKitchen />,
  },
  {
    title: "Plumbing",
    description:
      "Domestic water, sanitary and storm drainage design coordinated with the overall building system.",
    icon: <IconPlumb />,
  },
  {
    title: "Hydronic Systems",
    description:
      "Hot water heating, cooling and distribution systems with balanced hydraulics and controls.",
    icon: <IconHydro />,
  },
  {
    title: "Gas Piping",
    description:
      "Natural gas and propane piping design in reference to CSA B149 and applicable codes.",
    icon: <IconGas />,
  },
  {
    title: "Mechanical Permits",
    description:
      "Permit-ready drawings, calculations and documentation to support smooth municipal approvals.",
    icon: <IconPermit />,
  },
];

export default function Home() {
  return (
    <>
      <section className="hero">
        <div className="container hero-inner">
          <span className="hero-eyebrow">
            <span aria-hidden="true">â—†</span> Mechanical Engineering Â· Ontario
          </span>
          <h1>
            Mechanical engineering for buildings that perform.
          </h1>
          <p className="lead">
            AFZ Engineering Inc. is an Ontario mechanical engineering consultancy
            delivering HVAC, ventilation, heat loss and heat gain, duct, kitchen
            exhaust and make-up air, plumbing, hydronic and gas piping design,
            along with mechanical permit support.
          </p>
          <div className="hero-actions">
            <Link href="/services" className="btn btn-primary">
              Explore Services
            </Link>
            <Link href="/contact" className="btn btn-secondary">
              Start a Project
            </Link>
          </div>
        </div>
      </section>

      <section className="section" aria-labelledby="services-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="services-heading">What we do</h2>
            <p>
              A full range of mechanical engineering services for commercial,
              institutional and industrial projects across Ontario.
            </p>
          </div>
          <div className="card-grid">
            {SERVICES.map((s) => (
              <ServiceCard
                key={s.title}
                title={s.title}
                description={s.description}
                icon={s.icon}
                href="/services"
              />
            ))}
          </div>
        </div>
      </section>

      <section className="section section-soft" aria-labelledby="approach-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="approach-heading">Our approach</h2>
            <p>
              We work to the Ontario Building Code, ASHRAE, CSA B149, NFPA 96
              and HRAI principles, producing clear, coordinated and
              permit-ready documentation.
            </p>
          </div>
          <div className="card-grid">
            <div className="card">
              <h3>Code-Informed Design</h3>
              <p>
                Every system is developed against the applicable Ontario and
                national standards so the design stands up to review.
              </p>
            </div>
            <div className="card">
              <h3>Coordinated Documentation</h3>
              <p>
                Drawings, calculations and specifications are produced as a
                coherent set, reducing ambiguity for contractors and reviewers.
              </p>
            </div>
            <div className="card">
              <h3>Practical Solutions</h3>
              <p>
                We balance performance, constructability and lifecycle cost to
                deliver systems that are practical to build and operate.
              </p>
            </div>
          </div>
        </div>
      </section>

      <CTA />
    </>
  );
}