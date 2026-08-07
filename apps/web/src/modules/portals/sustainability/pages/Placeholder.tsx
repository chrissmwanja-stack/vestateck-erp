import PortalPlaceholder from "../../shared/PortalPlaceholder";
export default function SustainabilityPlaceholder(props: { title?: string; description?: string }) {
  return <PortalPlaceholder module="Sustainability" color="success" {...props} />;
}
