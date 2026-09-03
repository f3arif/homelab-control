import type { Metadata } from "next";
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

export const metadata: Metadata = {
  title: "Services",
  description:
    "Mechanical engineering services from AFZ Engineering Inc.: HVAC, heat loss and heat gain, duct design, ventilation, kitchen exhaust and make-up air, plumbing, hydronic, gas piping and mechanical permits.",
};

const SERVICES = [
  {
    title: "HVAC Design",
    description:
      "Design of heating, ventilation and air conditioning systems for commercial and institutional buildings. We size equipment, select systems and develop details that meet comfort, efficiency and code requirements.",
    icon: <IconHVAC />,
  },
  {
    title: "Heat Loss & Heat Gain",
    description:
      "Envelope and thermal load analysis to determine heating and cooling requirements. Accurate load work supports right-sized equipment and credible energy performance.",
    icon: <IconThermo />,
  },
  {
    title: "Duct Design",
    description:
      "Duct sizing, routing and pressure analysis for balanced air distribution. We coordinate ductwork with structure and other trades to keep systems efficient and quiet.",
    icon: <IconDuct />,
  },
  {
    title: "Ventilation",
    description:
      "Outdoor air, occupancy and contaminant-based ventilation strategies. We design systems that maintain healthy indoor air quality while meeting code minimums.",
    icon: <IconVent />,
  },
  {
    title: "Kitchen Exhaust & Make-Up Air",
    description:
      "Cooking equipment exhaust, capture and make-up air systems. Designs are developed in reference to NFPA 96 principles and applicable Ontario requirements.",
    icon: <IconKitchen />,
  },
  {
    title: "Plumbing",
    description:
      "Domestic water, sanitary and storm drainage design. We coordinate plumbing with the overall building system to support reliable operation and code compliance.",
    icon: <IconPlumb />,
  },
  {
    title: "Hydronic Systems",
    description:
      "Hot water heating, cooling and distribution systems. We develop balanced hydronic designs with appropriate controls for reliable, efficient operation.",
    icon: <IconHydro />,
  },
  {
    title: "Gas Piping",
    description:
      "Natural gas and propane piping design. Work is developed in reference to CSA B149 and the applicable Ontario requirements for gas distribution.",
    icon: <IconGas />,
  },
  {
    title: "Mechanical Permits",
    description:
      "Permit-ready drawings, calculations and documentation. We prepare the documentation needed to support smooth municipal approvals and construction.",
    icon: <IconPermit />,
  },
];

export default function ServicesPage() {
  return (
    <>
      <section className="page-hero">
        <div className="container">
          <h1>Services</h1>
          <p>
            A complete range of mechanical engineering services for commercial,
            institutional and industrial projects across Ontario.
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="services-detail">
        <div className="container">
          <div className="section-head">
            <h2 id="services-detail">Our services in detail</h2>
            <p>
              Each service is delivered with clear documentation and coordination
              across the mechanical disciplines.
            </p>
          </div>
          <div className="card-grid">
            {SERVICES.map((s) => (
              <ServiceCard
                key={s.title}
                title={s.title}
                description={s.description}
                icon={s.icon}
              />
            ))}
          </div>
        </div>
      </section>

      <section className="section section-soft" aria-labelledby="standards-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="standards-heading">Standards we work to</h2>
            <p>
              Our designs are developed in reference to the following, without
              implying any affiliation with the issuing bodies.
            </p>
          </div>
          <ul className="std-list">
            <li>
              <strong>Ontario Building Code</strong>
              <span>Baseline for mechanical design and safety.</span>
            </li>
            <li>
              <strong>ASHRAE</strong>
              <span>Principles for HVAC and ventilation performance.</span>
            </li>
            <li>
              <strong>CSA B149</strong>
              <span>Gas piping and equipment installation.</span>
            </li>
            <li>
              <strong>NFPA 96</strong>
              <span>Kitchen exhaust and make-up air systems.</span>
            </li>
            <li>
              <strong>HRAI</strong>
              <span>Heating and refrigeration industry principles.</span>
            </li>
          </ul>
        </div>
      </section>

      <CTA />
    </>
  );
}